export FrameworkModel, FrameworkParams

"""
    FrameworkParams

Structure to store the parameters of the framework model. The parameters are:
"""
struct FrameworkParams{T,P} <: AbstractEntropyScalingParams
    α::Array{T,2}
    m::Vector{Float64}
    σ::Vector{Float64}
    ε::Vector{Float64}
    Y₀⁺min::Vector{Float64}
    base::BaseParam{P}
end 

# Constructor for fitting
function FrameworkParams(prop::AbstractTransportProperty, eos, data; solute=nothing)
    α0 = get_α0_framework(prop)
    σ, ε, Y₀⁺min = init_framework_model(eos, prop; solute=solute)
    base = BaseParam(prop, get_Mw(eos), data; solute=solute)
    return FrameworkParams(α0, get_m(eos), σ, ε, Y₀⁺min, base)
end

# Constructor for existing parameters
function FrameworkParams(prop::AbstractTransportProperty, eos, α::Array{T,2}; 
                         solute=nothing) where {T}
    size(α,1) == 5 || error("Parameter array 'α' must have 5 rows.")
    size(α,2) == length(eos) || error("Parameter array 'α' doesn't fit EOS model.")

    σ, ε, Y₀⁺min = init_framework_model(eos, prop; solute=solute)
    return FrameworkParams(α, get_m(eos), σ, ε, Y₀⁺min, BaseParam(prop, get_Mw(eos)))
end

get_α0_framework(prop) = any(typeof(prop) .<: [Viscosity, DiffusionCoefficient]) ? zeros(Real,5,1) : [1.;zeros(Real,4,1);]

function init_framework_model(eos, prop; solute=nothing)
    # Calculation of σ and ε
    eos_pure = vcat(split_model(eos),isnothing(solute) ? [] : solute)
    cs = crit_pure.(eos_pure)
    (Tc, pc) = [getindex.(cs,i) for i in 1:2]
    σε = correspondence_principle.(Tc,pc)
    (σ, ε) = [getindex.(σε,i) for i in 1:2]

    if typeof(prop) == InfDiffusionCoefficient
        length(eos_pure) != 2 && error("Solvent and solute must each contain one component.")
        σ = mean(σ)*ones(length(eos))
        ε = geomean(ε)*ones(length(eos))
    end

    # Calculation of Ymin
    Ymin = Vector{Float64}(undef,length(eos))
    for i in 1:length(eos)
        optf = OptimizationFunction((x,p) -> property_CE_plus(prop,eos_pure[i], x[1], σ[i], ε[i]), AutoForwardDiff())
        prob = OptimizationProblem(optf, [2*Tc[i]])
        sol = solve(prob, Optimization.LBFGS(), reltol=1e-8)
        Ymin[i] = sol.objective[1]
    end

    return σ, ε, Ymin
end

"""
    FrameworkModel{T} <: AbstractEntropyScalingModel

A generic entropy scaling model.
"""
struct FrameworkModel{T} <: AbstractEntropyScalingModel
    components::Vector{String}
    params::Vector{FrameworkParams}
    eos::T
end

FrameworkModel(eos,params) = FrameworkModel(get_components(eos),params,eos)

function cite_model(::FrameworkModel) 
    print("Entropy Scaling Framework:\n---\n" *
          "(1) Schmitt, S.; Hasse, H.; Stephan, S. Entropy Scaling Framework for " * 
          "Transport Properties Using Molecular-Based Equations of State. Journal of " *
          "Molecular Liquids 2024, 395, 123811. DOI: " *
          "https://doi.org/10.1016/j.molliq.2023.123811")
    return nothing
end

function FrameworkModel(eos, param_dict::Dict{P,Array{T,2}}) where 
                        {T,P <: AbstractTransportProperty}
    params = FrameworkParams[]
    for (prop, α) in param_dict
        push!(params, FrameworkParams(prop, eos, α))
    end
    return FrameworkModel(eos, params)
end

function FrameworkModel(eos, datasets::Vector{TPD}; opts::FitOptions=FitOptions(), 
                        solute=nothing) where TPD <: TransportPropertyData
    # Check eos and solute
    length(eos) == 1 || error("Only one component allowed for fitting.")

    params = FrameworkParams[]
    for prop in [Viscosity(), ThermalConductivity(), SelfDiffusionCoefficient(), InfDiffusionCoefficient()]
        data = collect_data(datasets, prop)
        if data.N_dat > 0
            if typeof(prop) == InfDiffusionCoefficient 
                isnothing(solute) && error("Solute EOS model must be provided for diffusion coefficient at infinite dilution.")
                solute_ = solute
            else
                solute_ = nothing
            end

            # Init
            what_fit = prop in keys(opts.what_fit) ? opts.what_fit[prop] : [false;ones(Bool,4)]
            param = FrameworkParams(prop, eos, data; solute=solute_)

            #TODO make this a generic function
            # Calculate density 
            for k in findall(isnan.(data.ϱ))
                data.ϱ[k] = molar_density(eos, data.p[k], data.T[k])
            end

            # Scaling
            s = entropy_conf.(eos, data.ϱ, data.T)
            sˢ = reduced_entropy.(param,s)
            Yˢ = scaling.(param, eos, data.Y, data.T, data.ϱ, s)

            # Fit
            function resid!(du, p, xy)
                (xs,ys) = xy
                param.α[what_fit] .= p
                du .= scaling_model.(param,xs) .- ys
                return nothing
            end
            Yˢ_fit = prop == ThermalConductivity() ? Yˢ : log.(Yˢ)
            prob = NonlinearLeastSquaresProblem(
                NonlinearFunction(resid!, resid_prototype=similar(Yˢ)),
                randn(sum(what_fit)), (sˢ, Yˢ_fit),
            )
            sol = solve(prob, SimpleGaussNewton(), reltol=1e-8)
            α_fit = get_α0_framework(prop)
            α_fit[what_fit] .= sol.u
            
            push!(params, FrameworkParams(float.(α_fit), param.m, param.σ, param.ε, param.Y₀⁺min, param.base))
        end
    end
    return FrameworkModel(eos, params)
end

get_prop_type(::FrameworkParams{T,P}) where {T, P <: AbstractTransportProperty} = P

function Base.getindex(model::FrameworkModel, prop::P) where P <: AbstractTransportProperty
    tprop = typeof(prop)
    k = get_prop_type.(model.params) .== tprop
    if sum(k) == 1
        i = findfirst(k)
    elseif sum(k) == 0
        @info "No parameters for $tprop."
        i = k
    else
        @info "Multiple parameters for $tprop. Returning the first one."
        i = findfirst(k)
    end
    return model.params[i]
end


# Scaling model (correlation: Yˢ = Yˢ(sˢ,α,g))
function scaling_model(param::FrameworkParams{T,Viscosity}, s, x=[1.]) where T
    g = [-1.6386, 1.3923]
    return generic_scaling_model(param, s, x, g)
end
function scaling_model(param::FrameworkParams{T,ThermalConductivity}, s, x=[1.]) where T
    g = [-1.9107, 1.0725]
    return generic_scaling_model(param, s, x, g)
end
function scaling_model(param::FrameworkParams{T,P}, s, x=[1.]) where {T, P<:DiffusionCoefficient}
    g = [ 0.6632, 9.4714]
    return generic_scaling_model(param, s, x, g)
end

function generic_scaling_model(param::FrameworkParams, s, x, g)
    α = param.α * x
    return (α' * [1., log(s+1.), s, s^2, s^3]) / (1. + g' * [log(s+1.), s])
end

function scaling(param::FrameworkParams, eos, Y, T, ϱ, s, z=[1.]; inv=false)
    k = !inv ? 1 : -1

    # Entropy
    sˢ = reduced_entropy(param,s,z)

    # Transport property scaling
    Y₀⁺_all = property_CE_plus.(param.base.prop, split_model(eos), T, param.σ, param.ε)
    Y₀⁺ = mix_CE(param.base, Y₀⁺_all, z)
    Y₀⁺min = mix_CE(param.base, param.Y₀⁺min, z)
    
    W(x, sₓ=0.5, κ=20.0) = 1.0/(1.0+exp(κ*(x-sₓ)))
    Yˢ = (W(sˢ)/Y₀⁺ + (1.0-W(sˢ))/Y₀⁺min)^k * plus_scaling(param.base, Y, T, ϱ, s, z; inv=inv)

    return Yˢ
end

function reduced_entropy(param::FrameworkParams, s, z=[1.])
    return -s / R / sum(param.m .* z)
end

function viscosity(model::FrameworkModel, p, T, z=[1.]; phase=:unknown)
    ϱ = molar_density(model.eos, p, T, z; phase=phase)
    return ϱT_viscosity(model, ϱ, T, z)
end
function ϱT_viscosity(model::FrameworkModel, ϱ, T, z=[1.])
    param = model[Viscosity()]
    s = entropy_conf(model.eos, ϱ, T, z)
    sˢ = reduced_entropy(param, s, z)
    ηˢ = exp(scaling_model(param, sˢ, z))

    return scaling(param, model.eos, ηˢ, T, ϱ, s, z; inv=true) 
end

function thermal_conductivity(model::FrameworkModel, p, T, z=[1.]; phase=:unknown)
    ϱ = molar_density(model.eos, p, T, z; phase=phase)
    return ϱT_thermal_conductivity(model, ϱ, T, z)
end
function ϱT_thermal_conductivity(model::FrameworkModel, ϱ, T, z=[1.])
    param = model[ThermalConductivity()]
    s = entropy_conf(model.eos, ϱ, T, z)
    sˢ = reduced_entropy(param, s, z)
    λˢ = scaling_model(param, sˢ, z)

    return scaling(param, model.eos, λˢ, T, ϱ, s, z; inv=true) 
end

function self_diffusion_coefficient(model::FrameworkModel, p, T, z=[1.]; phase=:unknown)
    ϱ = molar_density(model.eos, p, T, z; phase=phase)
    if length(model) == 1
        return ϱT_self_diffusion_coefficient(model, ϱ, T)
    else
        return ϱT_self_diffusion_coefficient(model, ϱ, T, z)
    end
end

function ϱT_self_diffusion_coefficient(model::FrameworkModel, ϱ, T)
    param = model[SelfDiffusionCoefficient()]
    s = entropy_conf(model.eos, ϱ, T)
    sˢ = reduced_entropy(param, s)
    Dˢ = exp(scaling_model(param, sˢ))

    return scaling(param, model.eos, Dˢ, T, ϱ, s; inv=true) 
end

function ϱT_self_diffusion_coefficient(model::FrameworkModel, ϱ, T, z)
    param_self = model[SelfDiffusionCoefficient()]
    param_inf = model[InfDiffusionCoefficient()]
    s = entropy_conf(model.eos, ϱ, T, z)
    αi = similar(param_self.α)
    Di = similar(z)

    for i in 1:length(model.eos)
        αi[:,i] = param_self.α[:,i]
        αi[:,3-i] = param_inf.α[:,3-i]
        
        param = FrameworkParams(SelfDiffusionCoefficient(), model.eos, αi)
        sˢ = reduced_entropy(param, s, z)
        Dˢ = exp(scaling_model(param, sˢ, z))
        Di[i] = scaling(param, model.eos, Dˢ, T, ϱ, s, z; inv=true)
    end

    return Di
end

function MS_diffusion_coefficient(model::FrameworkModel, p, T, z; phase=:unknown)
    ϱ = molar_density(model.eos, p, T, z; phase=phase)
    return ϱT_MS_diffusion_coefficient(model, ϱ, T, z)
end
function ϱT_MS_diffusion_coefficient(model::FrameworkModel, ϱ, T, z)
    param = model[InfDiffusionCoefficient()]
    s = entropy_conf(model.eos, ϱ, T, z)
    sˢ = reduced_entropy(param, s, z)
    Dˢ = exp(scaling_model(param, sˢ, z))

    return scaling(param, model.eos, Dˢ, T, ϱ, s, z; inv=true) 
end