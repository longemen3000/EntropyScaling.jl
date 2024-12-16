export FrameworkModel, FrameworkParams

"""
    FrameworkParams{P<:AbstractTransportProperty,T<:Number}

Structure to store the parameters of the framework model. The parameters are:
- `α`: a matrix of size `(nparams,ncomponents)` containing the parameters of the corresponding transport property
- `m`: a vector of length `ncomponents` containing segment information
- `σ`: a vector of length `ncomponents` containing the molecular size parameters
- `ε`: a vector of length `ncomponents` containing the dispersion energies
- `Y₀⁺min`: vector of length `ncomponents` containing the minimum scaled property
- `base`: a `BaseParam` containing molecular weight, transport property and fitting information.
"""
struct FrameworkParams{P,T} <: AbstractEntropyScalingParams
    α::Matrix{T}
    m::Vector{Float64}
    σ::Vector{Float64}
    ε::Vector{Float64}
    Y₀⁺min::Vector{Float64}
    base::BaseParam{P}
end

# Constructor for fitting
function FrameworkParams(prop::AbstractTransportProperty, eos, data; solute=nothing)
    α0 = get_α0_framework(prop)
    σ, ε, Y₀⁺min = init_framework_params(eos, prop; solute=solute)
    base = BaseParam(prop, get_Mw(eos), data; solute=solute)
    return FrameworkParams(α0, get_m(eos), σ, ε, Y₀⁺min, base)
end

# Constructor for existing parameters
function FrameworkParams(prop::AbstractTransportProperty, eos, α::Array{T,2};
                         solute=nothing) where {T}
    size(α,1) == 5 || throw(DimensionMismatch("Parameter array 'α' must have 5 rows."))
    size(α,2) == length(eos) || throw(DimensionMismatch("Parameter array 'α' doesn't fit EOS model."))

    σ, ε, Y₀⁺min = init_framework_params(eos, prop; solute=solute)
    return FrameworkParams(α, convert(Vector{Float64},get_m(eos)), σ, ε, Y₀⁺min, BaseParam(prop, get_Mw(eos)))
end

# Constructor for merging multiple parameter sets
function FrameworkParams(self::FrameworkParams{<:SelfDiffusionCoefficient},
                         inf::FrameworkParams{<:InfDiffusionCoefficient}, idiff)

    what_inf = 1:length(self.base) .!= idiff
    new_self = deepcopy(self)
    new_self.α[:,what_inf] = inf.α[:,what_inf]
    for k in [:m,:σ,:ε,:Y₀⁺min]
        getfield(new_self,k)[what_inf] = getfield(inf,k)[what_inf]
    end
    new_self.base.Mw[what_inf] = inf.base.Mw[what_inf]
    
    return new_self
end


get_α0_framework(prop::Union{Viscosity,DiffusionCoefficient}) = zeros(Real,5,1)
get_α0_framework(prop) = [ones(Real,1);zeros(Real,4,1);]
function init_framework_params(eos, prop; solute = nothing, calculate_Ymin = true)
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
    if calculate_Ymin
        for i in 1:length(eos)
            optf = OptimizationFunction((x,p) -> property_CE_plus(prop, eos_pure[i], x[1], σ[i], ε[i]), AutoForwardDiff())
            prob = OptimizationProblem(optf, [2*Tc[i]])
            sol = solve(prob, Optimization.LBFGS(), reltol=1e-8)
            Ymin[i] = sol.objective[1]
        end
    else
        Ymin .= 0
    end
    return σ, ε, Ymin
end

"""
    FrameworkModel{T} <: AbstractEntropyScalingModel

A generic entropy scaling model.
"""
struct FrameworkModel{E,FP} <: AbstractEntropyScalingModel
    components::Vector{String}
    params::FP
    eos::E
end

@modelmethods FrameworkModel FrameworkParams

function cite_model(::FrameworkModel)
    print("Entropy Scaling Framework:\n---\n" *
          "(1) Schmitt, S.; Hasse, H.; Stephan, S. Entropy Scaling Framework for " *
          "Transport Properties Using Molecular-Based Equations of State. Journal of " *
          "Molecular Liquids 2024, 395, 123811. DOI: " *
          "https://doi.org/10.1016/j.molliq.2023.123811")
    return nothing
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


# Scaling model (correlation: Yˢ = Yˢ(sˢ,α,g))
function scaling_model(param::FrameworkParams{<:AbstractViscosity}, s, x=[1.])
    g = (-1.6386, 1.3923)
    return generic_scaling_model(param, s, x, g)
end
function scaling_model(param::FrameworkParams{<:AbstractThermalConductivity}, s, x=[1.])
    g = (-1.9107, 1.0725)
    return generic_scaling_model(param, s, x, g)
end
function scaling_model(param::FrameworkParams{<:DiffusionCoefficient}, s, x=[1.])
    g =  (0.6632, 9.4714)
    return generic_scaling_model(param, s, x, g)
end

function generic_scaling_model(param::FrameworkParams, s, x, g)
    α = param.α
    g1,g2 = g[1],g[2]
    num = zero(Base.promote_eltype(α,s,x,g))
    num += _dot(@view(α[1,:]),x) + _dot(@view(α[2,:]),x)*log1p(s)
    denom = 1 + g1*log1p(s) + g2*s
    si = s
    for i in 3:size(α,1)
        num += _dot(@view(α[i,:]),x)*si
        si *= s
    end
    return num/denom
end

#sigmoid function with bias
W(x, sₓ=0.5, κ=20.0) = 1.0/(1.0+exp(κ*(x-sₓ)))

function scaling(param::FrameworkParams, eos, Y, T, ϱ, s, z=[1.]; inv=false)
    k = !inv ? 1 : -1
    # Transport property scaling
    if length(z) == 1
        Y₀⁺ = property_CE_plus(param.base.prop, eos, T, param.σ[1], param.ε[1])
    elseif param.base.prop isa InfDiffusionCoefficient
        Y₀⁺ = property_CE_plus(MaxwellStefanDiffusionCoefficient(), eos, T, param.σ[1], param.ε[1], z)
    else
        Y₀⁺_all = property_CE_plus.(param.base.prop, split_model(eos), T, param.σ, param.ε, z)
        Y₀⁺ = mix_CE(param.base, Y₀⁺_all, z)
    end
    return scaling_property(param, eos, Y, Y₀⁺, T, ϱ, s, z; inv)
end

#TODO: better name??
function scaling_property(param::FrameworkParams, eos, Y, Y₀⁺, T, ϱ, s, z=[1.]; inv=false) 
    k = !inv ? 1 : -1
    Y₀⁺min = mix_CE(param.base, param.Y₀⁺min, z)
    # Entropy
    sˢ = reduced_entropy(param,s,z)
    Yˢ = (W(sˢ)/Y₀⁺ + (1.0-W(sˢ))/Y₀⁺min)^k * plus_scaling(param.base, Y, T, ϱ, s, z; inv=inv)
    return Yˢ
end

#TODO generalize
function ϱT_self_diffusion_coefficient(model::FrameworkModel, ϱ, T, z)
    param_self = model[SelfDiffusionCoefficient()]
    param_inf = model[InfDiffusionCoefficient()]
    s = entropy_conf(model.eos, ϱ, T, z)
    sˢ = reduced_entropy(param_self, s, z)
    Di = similar(z)

    for i in 1:length(model.eos)
        param = FrameworkParams(param_self, param_inf, i)
        Dˢ = exp(scaling_model(param, sˢ, z))
        Di[i] = scaling(param, model.eos, Dˢ, T, ϱ, s, z; inv=true)
    end

    return Di
end