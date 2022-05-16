__precompile__() # this module is safe to precompile
module IMinuit

using PyCall: PyObject, pycall, PyNULL, PyAny, PyVector, pyimport_conda, pyimport, pytype_mapping
import PyCall: PyObject, pycall, set!
# import PyCall: hasproperty # Base.hasproperty in Julia 1.2
import Base: convert, ==, isequal, hash, hasproperty, haskey

using ForwardDiff: gradient

export Minuit, migrad, minos, hesse, matrix, iminuit, args, model_fit, @model_fit
export AbstractFit, Fit, ArrayFit, func_argnames, Data, chisq, @plt_data, @plt_data!, @plt_best, @plt_best!
export gradient, LazyHelp, contour, mncontour, mnprofile, draw_mncontour, profile,
    draw_contour, draw_profile
export get_contours, get_contours_all, contour_df, get_contours_given_parameter
export contour_df_given_parameter, get_contours_samples, contour_df_samples

# copied from PyPlot.jl
# that lazily looks up help from a PyObject via zero or more keys.
# This saves us time when loading iminuit, since we don't have
# to load up all of the documentation strings right away.
struct LazyHelp
    o # a PyObject or similar object supporting getindex with a __doc__ property
    keys::Tuple{Vararg{String}}
    LazyHelp(o) = new(o, ())
    LazyHelp(o, k::AbstractString) = new(o, (k,))
    LazyHelp(o, k1::AbstractString, k2::AbstractString) = new(o, (k1, k2))
    LazyHelp(o, k::Tuple{Vararg{AbstractString}}) = new(o, k)
end
function show(io::IO, ::MIME"text/plain", h::LazyHelp)
    o = h.o
    for k in h.keys
        o = getproperty(o, k)
    end
    if hasproperty(o, "__doc__")
        print(io, "Docstring pulled from the Python `iminuit`:\n\n")
        print(io, convert(AbstractString, o."__doc__"))
    else
        print(io, "no Python docstring found for ", h.k)
    end
end

Base.show(io::IO, h::LazyHelp) = show(io, "text/plain", h)
function Base.Docs.catdoc(hs::LazyHelp...)
    Base.Docs.Text() do io
        for h in hs
            show(io, MIME"text/plain"(), h)
        end
    end
end


@doc raw"""
    method_argnames(m::Method)

Extracting the argument names of a method as an array.
Modified from [`methodshow.jl`](https://github.com/JuliaLang/julia/blob/master/base/methodshow.jl) 
(`Vector{Any}` changed to `Vector{Symbol}`).
"""
function method_argnames(m::Method)
    argnames = ccall(:jl_uncompress_argnames, Vector{Symbol}, (Any,), m.slot_syms)
    isempty(argnames) && return argnames
    return argnames[1:m.nargs]
end

"""
    func_argnames(f::Function)

Extracting the argument names of a function as an array.
"""
function func_argnames(f::Function)
    ms = collect(methods(f))
    return method_argnames(last(ms))[2:end]
end


###########################################################################

include("init.jl")
include("FitStructs.jl")

###########################################################################


# Wrappers of the iminuit functions
@doc raw"""
    Minuit(fcn, start; kwds...)
    Minuit(fcn, m::AbatractFit; kwds...)

Wrapper of the `iminuit` function `Minuit`.
* `fcn` is the function to be optimized.
* `start`: an array/tuple of the starting values of the parameters.
* `kwds` is the list of keyword arguments of `Minuit`. For more information, refer to the `iminuit` manual.
* `m`: a fit that was previously defined; its parameters at the latest stage can be passed to the new fit.

Example:
```
fit = Minuit(fcn, [1, 0]; name = ["a", "b"], error = 0.1*ones(2), 
            fix_a = true, limit_b = (0, 50) )
migrad(fit)
```
where the parameters are collected in an array `par` which is the argument of `fcn(par)`. In this case,
one can use external code (e.g., `using ForwardDiff: gradient`) to compute the gradient as 
`gradfun(par) = gradient(fcn, par)`, and include `grad = gradfun` as a keyword argument.


From `iminuit=2.11.2`:

`Minuit(fcn: Callable, *args: Union[float, iminuit.util.Indexable[float]], grad: Optional[Callable]
 = None, name: Optional[Collection[str]] = None, **kwds: float)`

"""
function Minuit(fcn, start; kwds...)::Fit
    if haskey(kwds, :name)
        tmp_fit = iminuit.Minuit(fcn, start, name=kwds[:name])
    else
        tmp_fit = iminuit.Minuit(fcn, start)
    end
    for k in keys(kwds)
        if k == :error
            tmp_fit.errors = kwds[k]
        elseif match(r"^fix_", string(k)) != nothing
            set!(tmp_fit.fixed, string(k)[5:end], kwds[k])
        elseif match(r"^limit_", string(k)) != nothing
            set!(tmp_fit.limits, string(k)[7:end], kwds[k])
        end
    end

    return tmp_fit
end
Minuit(fcn, m::ArrayFit; kwds...) = Minuit(fcn, args(m); (Symbol(k) => v for (k, v) in m.fitarg)..., kwds...)
Minuit(fcn, m::Fit; kwds...) = Minuit(fcn; (Symbol(k) => v for (k, v) in m.fitarg)..., kwds...)
# Todo



#########################################################################

include("Data.jl")
include("contour.jl")

#########################################################################


"""
    model_fit(model::Function, data::Data, start_values; kws...)

convenient wrapper for fitting a `model` to `data`; the returning stype is `ArrayFit`, which can be passed
to `migrad`, `minos` etc.
* `model` is the function to be fitted to `data`; it should be of the form `model(x, params)` with `params` given either as an array or a tuple.
* `start_values` can be either the initial values of parameters (`<: AbstractArray` or `<:Tuple`) or a previous fit of type `AbstractFit`.
"""
function model_fit(model::Function, data::Data, start_values; kws...)
    # _model(x, par) = length(func_argnames(model)) > 2 ? model(x, par...) : model(x, par)
    _chisq(par) = chisq(model, data, par)
    _fit = Minuit(_chisq, start_values; kws...)
    return _fit
end

"""
    @model_fit model data start_values kws...

convenient wrapper for fitting a `model` to `data`; see [`model_fit`](@ref).
"""
macro model_fit(model, data, start_values, kws...)
    _expr = quote
        _chisq(par) = chisq($model, $data, par)
        _fit = isempty($kws) ? Minuit(_chisq, $start_values) : Minuit(_chisq, $start_values; $(kws...))
    end
    esc(_expr)
end


end
