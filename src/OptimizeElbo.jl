# written by Jeffrey Regier
# jeff [at] stat [dot] berkeley [dot] edu

module OptimizeElbo

using NLopt
using CelesteTypes
using Transform

import ElboDeriv


#TODO: use Lumberjack.jl for logging
const debug = false


function get_nlopt_bounds(vs::Vector{Float64})
    # Note that sources are not allowed to move more than
    # one pixel from their starting position in order to
    # avoid label switiching.  (This is why this function gets
    # the variational parameters as an argument.)
    # vs: parameters for a particular source.
    # vp: complete collection of sources.
    lb = Array(Float64, length(CanonicalParams))
    lb[ids.a] = 1e-2
    lb[ids.u] = vs[ids.u] - 1.
    [lb[id] = 1e-4 for id in ids.r1]
    [lb[id] = 1e-4 for id in ids.r2]
    [lb[id] = 1e-4 for id in ids.k]
    [lb[id] = -10. for id in ids.c1]
    [lb[id] = 1e-4 for id in ids.c2]
    lb[ids.e_dev] = 1e-2
    lb[ids.e_axis] = 1e-4
    lb[ids.e_angle] = -1e10 #-pi/2 + 1e-4
    lb[ids.e_scale] = 0.2

    ub = Array(Float64, length(CanonicalParams))
    ub[ids.a] = 1 - 1e-2
    ub[ids.u] = vs[ids.u] + 1.
    [ub[id] = 1e12 for id in ids.r1]
    [ub[id] = 1e-1 for id in ids.r2]
    [ub[id] = 1 - 1e-4 for id in ids.k]
    [ub[id] = 10. for id in ids.c1]
    [ub[id] = 1. for id in ids.c2]
    ub[ids.e_dev] = 1 - 1e-2
    ub[ids.e_axis] = 1. - 1e-4
    ub[ids.e_angle] = 1e10 #pi/2 - 1e-4
    ub[ids.e_scale] = 15.

    lb, ub
end


function get_nlopt_unconstrained_bounds(vp::Vector{Vector{Float64}},
                                        omitted_ids::Vector{Int64},
                                        transform::DataTransform)
    # Note that sources are not allowed to move more than
    # one pixel from their starting position in order to
    # avoid label switiching.  (This is why this function gets
    # the variational parameters as an argument.)
    #
    # vp: _Constrained_ variational parameters.
    # omitted_ids: Ids of _unconstrained_ variational parameters to be omitted.
    # unconstrain_fn: A function to convert VariationalParameters to a
    #   vector that can be passed to the optimizer.

    lbs = [get_nlopt_bounds(vs)[1] for vs in vp]
    ubs = [get_nlopt_bounds(vs)[2] for vs in vp]
    (transform.vp_to_vector(lbs, omitted_ids), 
        transform.vp_to_vector(ubs, omitted_ids))
end


function print_params(vp)
    for vs in vp
        for n in names(ids)
            println("$n: $(vs[ids.(n)])")
        end
        println("-----------------\n")
    end
end


function maximize_f(f::Function, blob::Blob, mp::ModelParams, transform::DataTransform,
                    lbs::Array{Float64, 1}, ubs::Array{Float64, 1};
                    omitted_ids=Int64[], xtol_rel = 1e-7, ftol_abs = 1e-6)
    # Maximize using NLOpt and unconstrained coordinates.
    #
    # Args:
    #   - f: A function that takes a blob and constrianed coordinates (e.g. ElboDeriv.elbo)
    #   - blob: Input for f
    #   - mp: Constrained initial ModelParams
    #   - transform: The data transform to be applied before optimizing.
    #   - lbs: An array of lower bounds (in the transformed space)
    #   - ubs: An array of upper bounds (in the transformed space)
    #   - omitted_ids: Omitted ids from the _unconstrained_ parameterization (i.e. elements
    #       of free_ids).

    x0 = transform.vp_to_vector(mp.vp, omitted_ids)
    iter_count = 0

    function objective_and_grad(x::Vector{Float64}, g::Vector{Float64})
        println("Iter: ", iter_count)
        # Evaluate in the constrained space and then unconstrain again.
        transform.vector_to_vp!(x, mp.vp, omitted_ids)
        elbo = f(blob, mp)
        elbo_trans = transform.transform_sensitive_float(elbo, mp)
        left_ids = setdiff(1:length(UnconstrainedParams), omitted_ids)
        if length(g) > 0
            svs = [elbo_trans.d[left_ids, s] for s in 1:mp.S]
            g[:] = reduce(vcat, svs)
        end

        iter_count += 1
        debug && print_params(mp.vp)
        (debug || iter_count % 10 == 0) && 
            println("iter $iter_count elbo: $(elbo.v)")
        debug && println("\n=======================================\n")
        elbo.v
    end

    opt = Opt(:LD_LBFGS, length(x0))
    for i in 1:length(x0)
        if !(lbs[i] <= x0[i] <= ubs[i])
            println("coordinate $i falsity: $(lbs[i]) <= $(x0[i]) <= $(ubs[i])")
        end
    end
    lower_bounds!(opt, lbs)
    upper_bounds!(opt, ubs)
    max_objective!(opt, objective_and_grad)
    xtol_rel!(opt, xtol_rel)
    ftol_abs!(opt, ftol_abs)
    (max_f, max_x, ret) = optimize(opt, x0)

    println("got $max_f at $max_x after $iter_count iterations (returned $ret)\n")
    iter_count, max_f, max_x, ret
end

function maximize_f(f::Function, blob::Blob, mp::ModelParams, transform::DataTransform;
    omitted_ids=Int64[], xtol_rel = 1e-7, ftol_abs = 1e-6)
    # Default to the bounds given in get_nlopt_unconstrained_bounds.

    lbs, ubs = get_nlopt_unconstrained_bounds(mp.vp, omitted_ids, transform)
    maximize_f(f, blob, mp, transform, lbs, ubs;
               omitted_ids=omitted_ids, xtol_rel=xtol_rel, ftol_abs=ftol_abs)
end

function maximize_f(f::Function, blob::Blob, mp::ModelParams;
    omitted_ids=Int64[], xtol_rel = 1e-7, ftol_abs = 1e-6)
    # Default to the world rectangular transform

    maximize_f(f, blob, mp, world_rect_transform,
               omitted_ids=omitted_ids, xtol_rel=xtol_rel, ftol_abs=ftol_abs)
end

function maximize_elbo(blob::Blob, mp::ModelParams, trans::DataTransform;
    xtol_rel = 1e-7, ftol_abs=1e-6)
    omitted_ids = setdiff(1:length(UnconstrainedParams),
                          [ids_free.r1, ids_free.r2,
                           ids_free.k[:], ids_free.c1[:]])
    maximize_f(ElboDeriv.elbo, blob, mp, trans, omitted_ids=omitted_ids,
        ftol_abs=ftol_abs, xtol_rel=xtol_rel)

    maximize_f(ElboDeriv.elbo, blob, mp, trans, ftol_abs=ftol_abs, xtol_rel=xtol_rel)
end

function maximize_elbo(blob::Blob, mp::ModelParams)
    # Default to the rectangular transform.
    maximize_elbo(blob, mp, world_rect_transform)
end

function maximize_likelihood(blob::Blob, mp::ModelParams, trans::DataTransform; xtol_rel = 1e-7, ftol_abs=1e-6)
    omitted_ids = [ids_free.k[:], ids_free.c2[:], ids_free.r2]
    maximize_f(ElboDeriv.elbo_likelihood, blob, mp, trans,
               omitted_ids=omitted_ids, xtol_rel=xtol_rel, ftol_abs=ftol_abs)
end

function maximize_likelihood(blob::Blob, mp::ModelParams)
    # Default to the rectangular transform.
    maximize_likelihood(blob, mp, world_rect_transform)
end

end
