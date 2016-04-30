# Test the functions that move between constrained and unconstrained
# parameterizations.

using Celeste: Transform, SensitiveFloats
using Compat

include("derivative_utils.jl")


"""
Generate parameters within the given bounds.
"""
function generate_valid_parameters(
    NumType::DataType, bounds_vec::Vector{ParamBounds})

    @assert NumType <: Number
    S = length(bounds_vec)
    vp = convert(VariationalParams{NumType},
                                 [ zeros(NumType, length(ids)) for s = 1:S ])
        for s=1:S, (param, constraint_vec) in bounds_vec[s]
        is_box = isa(constraint_vec, Array{ParamBox})
        if is_box
            # Box parameters.
            for ind in 1:length(ids.(param))
                constraint = constraint_vec[ind]
                constraint.upper_bound == Inf ?
                    vp[s][ids.(param)[ind]] = constraint.lower_bound + 1.0:
                    vp[s][ids.(param)[ind]] =
                        0.5 * (constraint.upper_bound - constraint.lower_bound) +
                        constraint.lower_bound
            end
        else
            # Simplex parameters can ignore the bounds.
            param_size = size(ids.(param))
            if length(param_size) == 2
                # matrix simplex
                for col in 1:param_size[2]
                    vp[s][ids.(param)[:, col]] = 1 / param_size[1]
                end
            else
                # vector simplex
                vp[s][ids.(param)] = 1 / length(ids.(param))
            end
        end
        end

    vp
end


function test_transform_sensitive_float()
	blob, ea, body, tiled_blob = gen_two_body_dataset();

	# Only keep a few pixels to make the autodiff results faster.
  keep_pixels = 10:11
	for b = 1:length(tiled_blob)
	  tiled_blob[b].tiles[1,1].pixels[
			setdiff(1:tiled_blob[b].tiles[1,1].h_width, keep_pixels), :] = NaN;
	  tiled_blob[b].tiles[1,1].pixels[
			:, setdiff(1:tiled_blob[b].tiles[1,1].w_width, keep_pixels)] = NaN;
	end


	function wrap_elbo{NumType <: Number}(vp_free_vec::Vector{NumType})
		vp_free_array = reshape(vp_free_vec, length(UnconstrainedParams), length(ea.active_sources))
		vp_free = Vector{NumType}[ zeros(NumType, length(UnconstrainedParams)) for
		                           sa in ea.active_sources ];
		Transform.array_to_free_vp!(vp_free_array, vp_free, Int[])
		ea_local = forward_diff_model_params(NumType, ea);
		transform.to_vp!(vp_free, ea_local.vp)
		elbo = ElboDeriv.elbo(tiled_blob, ea_local, calculate_derivs=false)
		elbo.v[1]
	end

	transform = Transform.get_mp_transform(ea, loc_width=1.0);
	elbo = ElboDeriv.elbo(tiled_blob, ea);
	elbo_trans = transform.transform_sensitive_float(elbo, ea);

	free_vp_vec = reduce(vcat, transform.from_vp(ea.vp));
	ad_grad = ForwardDiff.gradient(wrap_elbo, free_vp_vec);
	ad_hess = ForwardDiff.hessian(wrap_elbo, free_vp_vec);

	@test_approx_eq ad_grad reduce(vcat, elbo_trans.d)
	@test_approx_eq ad_hess elbo_trans.h

  # Test with a subset of sources.
	ea.active_sources = [2]
	transform = Transform.get_mp_transform(ea, loc_width=1.0);
	elbo = ElboDeriv.elbo(tiled_blob, ea);
	elbo_trans = transform.transform_sensitive_float(elbo, ea);

	free_vp_vec = reduce(vcat, transform.from_vp(ea.vp));
	ad_grad = ForwardDiff.gradient(wrap_elbo, free_vp_vec);
	ad_hess = ForwardDiff.hessian(wrap_elbo, free_vp_vec);

	@test_approx_eq ad_grad reduce(vcat, elbo_trans.d)
	@test_approx_eq ad_hess elbo_trans.h
end


function test_box_derivatives()
	blob, ea, body = gen_three_body_dataset();
	transform = get_mp_transform(ea, loc_width=1.0);

	box_params = setdiff(fieldnames(ids), [:a, :k])
	vp_free = transform.from_vp(ea.vp)
	for sa = 1:length(ea.active_sources), param in box_params, ind in length(ids.(param))
		# sa = 1
		# param = box_params[1]
		# ind = 1

		s = ea.active_sources[sa]
		vp_ind = ids.(param)[ind]
		free_ind = [ids_free.(param)[ind]]

		function wrap_transform{NumType <: Number}(vp_free_s::Vector{NumType})
			local_vp_free =
				Array{NumType, 1}[ convert(Array{NumType, 1}, vp_free[sa]) for
			                  sa = 1:length(ea.active_sources) ]
			local_vp_free[s] = vp_free_s
			vp = transform.to_vp(local_vp_free)
			vp[s][ids.(param)[ind]]
		end

		ad_d  = ForwardDiff.gradient(wrap_transform, vp_free[s])[free_ind][1]
		ad_h = ForwardDiff.hessian(wrap_transform, vp_free[s])[free_ind, free_ind][1,1]

		d, h = Transform.box_derivatives(
			ea.vp[s][vp_ind][1], transform.bounds[s][param][ind])
		@test_approx_eq ad_d d
		@test_approx_eq ad_h h
	end
end


function test_box_simplex_derivatives()
	blob, ea, body = gen_three_body_dataset();
	for s = 1:ea.S
		delta = 0.01 * s # Make the parameters different for each one
		ea.vp[s][ids.a] = Float64[ 0.2 - delta, 0.8 + delta ]
		ea.vp[s][ids.k] = Float64[ 0.2- delta 0.2- delta; 0.8 + delta 0.8 + delta ]
	end
	transform = get_mp_transform(ea, loc_width=1.0);

	simplex_params = [:a, :k]
	vp_free = transform.from_vp(ea.vp)

	for sa = 1:length(ea.active_sources), param in simplex_params
		# sa = 1
		# param = :k
		# col = 1 # For k only
		# ind = 1 # Index within the simplex

		s = ea.active_sources[sa]
		num_cols = length(size(ids.(param)))
		@assert num_cols == 1 || num_cols == 2

		for col = 1:num_cols
			vp_ind = ids.(param)[:, col]

			if length(size(ids_free.(param))) == 0
				# Hack to handle ids_free.a
				@assert col == 1
				free_ind = [ ids_free.(param) ]
			else
				free_ind = ids_free.(param)[:, col]
			end

			d, h = Transform.box_simplex_derivatives(
				ea.vp[s][vp_ind], transform.bounds[s][param][col])

			for row = 1:2
				# Write with a univariate output so we can take autodiff hessians.
			  function wrap_transform{NumType <: Number}(vp_free_s::Vector{NumType})
			  	local_vp_free =
			  		Array{NumType, 1}[ convert(Array{NumType, 1}, vp_free[sa]) for
			  	                     sa = 1:length(ea.active_sources) ]
			  	local_vp_free[s] = vp_free_s
			  	vp = transform.to_vp(local_vp_free)
			  	vp[s][ids.(param)[row, col]]
			  end

			  ad_d = ForwardDiff.gradient(wrap_transform, vp_free[s])[free_ind]
			  ad_h = ForwardDiff.hessian(wrap_transform, vp_free[s])[free_ind, free_ind]
				@test_approx_eq ad_d d[row, :][1]
				@test_approx_eq ad_h h[row]
			end
		end
	end
end


function test_simplex_derivatives()
	n = 4
	basic_simplex_box = Transform.SimplexBox(0, 1, n)
	z = Float64[1, 2, 4, 3]
	z /= sum(z)
	r = Transform.unsimplexify_parameter(z, basic_simplex_box)
	Transform.simplexify_parameter(r, basic_simplex_box)

	ad_d = Array(Array{Float64}, n)
	ad_h = Array(Array{Float64}, n)

	for ind = 1:n
	  function wrap_simplex{NumType <: Number}(r::Vector{NumType})
	    local z = Transform.simplexify_parameter(r, basic_simplex_box)
	    z[ind]
	  end
	  ad_d[ind] = ForwardDiff.gradient(wrap_simplex, r)
	  ad_h[ind] = ForwardDiff.hessian(wrap_simplex, r)
	end

	jacobian, hessian_vec = Transform.simplex_derivatives(z)

	@test_approx_eq jacobian' reduce(hcat, ad_d)
	for ind = 1:n
		@test_approx_eq(hessian_vec[ind], ad_h[ind])
	end
end


function test_parameter_conversion()
	blob, ea, body = gen_three_body_dataset();

	transform = get_mp_transform(ea, loc_width=1.0);

	function check_transform(transform::DataTransform, ea::ElboArgs)
		original_vp = deepcopy(ea.vp);
		ea_check = deepcopy(ea);

		# Check that the constrain and unconstrain operations undo each other.
		vp_free = transform.from_vp(ea.vp)
		transform.to_vp!(vp_free, ea_check.vp)

		for id in fieldnames(ids), s in 1:ea.S
			@test_approx_eq_eps(original_vp[s][ids.(id)],
			                    ea_check.vp[s][ids.(id)], 1e-6)
		end

		# Check conversion to and from a vector.
		omitted_ids = Array(Int, 0)
		vp = deepcopy(ea.vp)
		x = transform.vp_to_array(vp, omitted_ids)
		@test length(x) == length(vp_free[1]) * length(ea.active_sources)

		vp2 = generate_valid_parameters(Float64, transform.bounds)
		transform.array_to_vp!(x, vp2, omitted_ids)
		for id in fieldnames(ids), si in 1:transform.active_S
			s = transform.active_sources[si]
			@test_approx_eq_eps(original_vp[s][ids.(id)], vp2[si][ids.(id)], 1e-6)
		end

	end

	transform = get_mp_transform(ea, loc_width=1.0);
	check_transform(transform, ea)

	# Test transforming only active sources.
	ea1 = deepcopy(ea);
	ea1.active_sources = [1]
	transform1 = Transform.get_mp_transform(ea1)

	@assert transform1.S == ea.S
	@assert transform1.active_S == 1
	check_transform(transform1, ea1)

end


function test_transform_simplex_functions()
	function simplex_and_unsimplex{NumType <: Number}(
			param::Vector{NumType}, simplex_box::Transform.SimplexBox)

		param_free = Transform.unsimplexify_parameter(param, simplex_box)
		new_param = Transform.simplexify_parameter(param_free, simplex_box)
		@test_approx_eq param new_param
	end

	for this_scale = [ 1.0, 2.0 ], lb = [0.1, 0.0 ]
		param = Float64[ 0.2, 0.8 ]

		simplex_box = Transform.SimplexBox(lb, this_scale, length(param))
		simplex_and_unsimplex(param, simplex_box)

		# Test that the edges work.
		simplex_and_unsimplex(Float64[ lb, 1 - lb ], simplex_box)
		simplex_and_unsimplex(Float64[ 1 - lb, lb ], simplex_box)

		# Test the scaling
		unscaled_simplex_box = Transform.SimplexBox(lb, 1.0, length(param))
		@test_approx_eq(
			Transform.unsimplexify_parameter(param, simplex_box),
			this_scale * Transform.unsimplexify_parameter(param, unscaled_simplex_box))

		# Test the bound checking
		@test_throws(AssertionError,
			Transform.unsimplexify_parameter([ lb - 1e-6, 1 - lb + 1e-6 ], simplex_box))
		@test_throws(AssertionError,
			Transform.unsimplexify_parameter([ 0.3, 0.8 ], simplex_box))
		@test_throws(AssertionError,
			Transform.unsimplexify_parameter([ 0.2, 0.3, 0.5 ], simplex_box))
		@test_throws(AssertionError, Transform.simplexify_parameter([ 1., 2. ], simplex_box))
	end
end


function test_transform_box_functions()
	function box_and_unbox{NumType <: Number}(param::NumType, param_box::ParamBox)
		param_free = Transform.unbox_parameter(param, param_box)
		new_param = Transform.box_parameter(param_free, param_box)
		@test_approx_eq param new_param
	end

	for this_scale = [ 1.0, 2.0 ], lb = [-10.0, 0.1], ub = [0.5, Inf]
		#println(this_scale, " ", lb, " ", ub)
		param = 0.2
		param_box = Transform.ParamBox(lb, ub, this_scale)
		box_and_unbox(param, param_box)

		# Test that the edges work.
		box_and_unbox(lb, param_box)
		ub < Inf && box_and_unbox(ub, param_box)

		# Test the scaling
		unscaled_param_box = Transform.ParamBox(lb, ub, 1.0)
		@test_approx_eq(
			Transform.unbox_parameter(param, param_box),
			this_scale * Transform.unbox_parameter(param, unscaled_param_box))

		# Test the bound checking
		@test_throws AssertionError Transform.unbox_parameter(lb - 1.0, param_box)
		ub < Inf &&
			@test_throws AssertionError Transform.unbox_parameter(ub + 1.0, param_box)
	end
end


function test_basic_transforms()
	@test_approx_eq 0.99 Transform.logit(Transform.inv_logit(0.99))
	@test_approx_eq -6.0 Transform.inv_logit(Transform.logit(-6.0))

	@test_approx_eq(
		[ 0.99, 0.001 ], Transform.logit(Transform.inv_logit([ 0.99, 0.001 ])))
	@test_approx_eq(
		[ -6.0, 0.5 ], Transform.inv_logit(Transform.logit([ -6.0, 0.5 ])))

	z = Float64[ 2.0, 4.0 ]
	z ./= sum(z)
	x = Transform.unconstrain_simplex(z)

	@test_approx_eq Transform.constrain_to_simplex(x) z

	@test Transform.inv_logit(1.0) == Inf
	@test Transform.inv_logit(0.0) == -Inf

	@test Transform.logit(Inf) == 1.0
	@test Transform.logit(-Inf) == 0.0

	@test_approx_eq Transform.constrain_to_simplex([-Inf]) [0.0, 1.0]
	@test_approx_eq Transform.unconstrain_simplex([0.0, 1.0]) [-Inf]

	@test_approx_eq Transform.constrain_to_simplex([Inf]) [1.0, 0.0]
	@test_approx_eq Transform.unconstrain_simplex([1.0, 0.0]) [Inf]

	@test_approx_eq Transform.constrain_to_simplex([Inf, 5]) [1.0, 0.0, 0.0]
end


function test_enforce_bounds()
	blob, ea, three_bodies = gen_three_body_dataset();
	transform = get_mp_transform(ea);

	ea.vp[1][ids.a[1]] = transform.bounds[1][:a][1].lower_bound - 0.00001
	ea.vp[2][ids.r1[1]] = transform.bounds[2][:r1][1].lower_bound - 1.0
	ea.vp[2][ids.r1[2]] = transform.bounds[2][:r1][1].upper_bound + 1.0
	ea.vp[3][ids.k[1, 1]] = transform.bounds[3][:k][1, 1].lower_bound - 0.00001

	@test_throws AssertionError transform.from_vp(ea.vp)
	Transform.enforce_bounds!(ea, transform)

	# Check that it now works and all values are finite.
	x_trans = transform.from_vp(ea.vp)
	for s = 1:ea.S
		@test !any(Bool[ isinf(x) for x in x_trans[1] ])
	end

	# Test with only one active source.
	sa = 2
	ea.active_sources = [sa]
	transform = get_mp_transform(ea);

	ea.vp[sa][ids.a[1]] = transform.bounds[1][:a][1].lower_bound - 0.00001
	ea.vp[sa][ids.r1[1]] = transform.bounds[1][:r1][1].lower_bound - 1.0
	ea.vp[sa][ids.r1[2]] = transform.bounds[1][:r1][1].upper_bound + 1.0
	ea.vp[sa][ids.k[1, 1]] = transform.bounds[1][:k][1, 1].lower_bound - 0.00001

	@test_throws AssertionError transform.from_vp(ea.vp)
	Transform.enforce_bounds!(ea, transform)

	# Check that it now works and all values are finite.
	x_trans = transform.from_vp(ea.vp)
	for s = 1:ea.S
		@test !any(Bool[ isinf(x) for x in x_trans[1] ])
	end

end


test_transform_box_functions()
test_transform_sensitive_float()
test_box_derivatives()
test_box_simplex_derivatives()
test_simplex_derivatives()
test_parameter_conversion()
test_transform_simplex_functions()
test_basic_transforms()
test_enforce_bounds()
