using Distributed, Pkg
Pkg.activate(joinpath(@__DIR__, "."))
using MLPGradientFlow
const activation_function = getproperty(MLPGradientFlow, Meta.parse(ARGS[1]))
addprocs(48, exeflags="--project=$(joinpath(@__DIR__, "."))")
@everywhere begin
include(joinpath(@__DIR__, "helper.jl"))

using Optim, OrdinaryDiffEq

# TODO: make this even stricter; ideas
# - look at slope of loss curve and it's fluctuations
# - look at changes in x (momentum?)
function converge_to_fixed_point(net, x;
                                 max_iters = 10,
                                 maxiterations_per_iter = 10^5,
                                 maxtime_per_iter = 5*60,
                                 minimal_abs_drop = 0,
                                 minimal_rel_drop = 0,
                                 patience = 2,
                                 convergence_solver = length(x) < 10^3 ? Newton() : BFGS(),
                                 rescale = isa(convergence_solver, BFGS),
                                 kwargs...)
    res = train(net, x; kwargs...)
    init = params(res["x"])
    oldl = res["loss"]
    res2 = Dict{String, Any}()
    success_iter = 0
    drops = Float64[]
    kwa = merge(NamedTuple(kwargs), (maxiterations_ode = 0,
                         optim_solver = convergence_solver,
                         loss_scale = rescale ? 1/sqrt(oldl) : 1.,
                         maxiterations_optim = maxiterations_per_iter,
                         maxtime_optim = maxtime_per_iter))
    for iter in 1:max_iters
        res2 = train(net, init; kwa...)
        latest_drop = oldl - res2["loss"]
        push!(drops, latest_drop)
        if length(drops) > patience
            latest_drops = sum(drops[end-patience:end])
            if latest_drops ≤ minimal_abs_drop ||
               latest_drops/res2["loss"] ≤ minimal_rel_drop
                success_iter = iter
                break
            end
        end
        oldl = res2["loss"]
        init = params(res2["x"])
    end
    res, res2, (success_iter, drops)
end
end

settings = collect(Iterators.product(1:50, (2, 4), (1, 3//2, 2, 3)))

@sync @distributed for (seed, k, ρ) in settings
    @show seed k ρ
    net, x, xt = setup(seed = seed, Din = k, k = k, r = k*ρ, f = activation_function)
#     res = converge_to_fixed_point(net, x,
#                                   maxtime_per_iter = 3600,
#                                   maxtime_ode = 4*3600,
#                                   maxtime_optim = 5*3600,
#                                   maxiterations_per_iter = 10^4,
#                                   maxiterations_ode = 10^4,
#                                   maxiterations_optim = 10^4,
#                                   maxnorm = 5*10^3,
#                                   g_tol = 1e-16,
#                                  )
    res = train(net, x,
                maxtime_ode = 10*3600,
                maxtime_optim = 10*3600,
                maxiterations_ode = 10^9,
                maxiterations_optim = 10^9,
                maxnorm = 10^3,
                g_tol = 1e-16,
                patience = 10^4)
    serialize("fp5-$activation_function-$seed-$k-$ρ.dat", (; seed, k, ρ, res, xt))
end

function getnorms(net, x)
    N = size(net.input, 2)
    dx = gradient(net, x)
    dx ./= N
    gnorm = sqrt(sum(abs2, dx))
    gnorminf = maximum(abs, dx)
    nx = sum(abs2, x)/(2*length(x))
    c = 10^3
    if nx > c
        dx .+= (nx - c)*x/(N*length(x))
    end
    gnorm_reg = sqrt(sum(abs2, dx))
    gnorminf_reg = maximum(abs, dx)
    (; gnorm, gnorminf, gnorm_reg, gnorminf_reg)
end
df = DataFrame(seed = Int[], k = String[], ρ = String[],
               success_iter = Int[],
               drops = Float64[],
               ode_loss = Float64[],
               loss = Float64[],
               loss1 = Float64[],
               ode_gnorminf_reg = Float64[],
               gnorminf_reg = Float64[],
               mineigval = Float64[],
               gnorm = Float64[],
               gnorm_reg = Float64[],
               gnorminf = Float64[],
               activation_function = String[],
               res = [], res2 = [],
              )
for (seed, k, ρ) in settings
    for activation in (g,)
#         f = "simsjuly23/fp3-$activation-$seed-$k-$ρ.dat"
        f = "simsjuly23/fp5-$activation-$seed-$k-$ρ.dat"
        isfile(f) || continue
        net, x, xt = setup(seed = seed, Din = k, k = k, r = k*ρ, f = activation)
        _, _, _, res, _ = deserialize(f)
        finalres = res
        res1 = finalres
#         finalres = res[2]
#         res1 = res[1]
        sol = params(finalres["x"])
        gnorm, gnorminf, gnorm_reg, gnorminf_reg = getnorms(net, sol)
        ode_gnorm, ode_gnorminf, ode_gnorm_reg, ode_gnorminf_reg = getnorms(net, params(res1["ode_x"]))
        if isnan(sum(sol))
            mineigval = NaN
        else
            mineigval = first(first(hessian_spectrum(net, sol)))
        end
        push!(df, [seed, "$k", "$ρ",
                   0,
                   0,
#                    res[3][1],
#                    res[3][2][end],
                   res1["ode_loss"],
                   finalres["loss"],
                   res1["loss"],
                   ode_gnorminf_reg,
                   gnorminf_reg,
                   mineigval,
                   gnorm,
                   gnorm_reg,
                   finalres["gnorm"],
                   "$activation",
                   res1, finalres])
    end
end
function paramnorm(res)
    x = params(res["x"])
    sum(abs2, x)/2
end
import MLPGradientFlow: pairwise, similarity
import LinearAlgebra: I
function largest_pairwise_sim(res)
    w1 = params(res["x"]).w1
    maximum(pairwise(similarity, w1) - I)
end
function smallest_pairwise_dist(res)
    w1 = params(res["x"]).w1
    minimum(pairwise((x, y) -> sum(abs2, x - y)/length(x), w1) + 100I)
end
df.mineigvalsclass = (x -> x < -1e-8 ? 1 :
                      x < 0 ? 2 :
                      x < 1e-8 ? 3 : 4).(df.mineigval)
minimum(df.mineigval) > -1e-8
df.nparams = (x -> length(params(x["x"]))).(df.res2)
df.kind = (((x, y),) -> "$x-$y").(zip(df.k, df.ρ))
df.xnorm = paramnorm.(df.res2)
df.largest_pairwise_sim = largest_pairwise_sim.(df.res2)
df.sm_pairwise_sim = 1 .- df.largest_pairwise_sim
df.smallest_pairwise_dist = smallest_pairwise_dist.(df.res2)
df.on_saddle = df.largest_pairwise_sim .≈ 1
df.infty = df.xnorm .> 4800;
df.wtf = df.on_saddle

dff = leftjoin(df, df1, on = [:seed, :k, :ρ], makeunique = true)
dff = leftjoin(dff, df2, on = [:seed, :k, :ρ], makeunique = true)
dropmissing!(dff)

maximum(dff.loss - dff.loss_2)

dff.dl = dff.loss - dff.loss_2
sort!(dff, :dl)

@pgf Axis({xmode = "log", ymode = "log", xlabel = "loss", ylabel = "xnorm"},
          Plot({"scatter",
        "only marks",
        "scatter src" = "explicit symbolic",
        "scatter/classes" =
        {
         "1" = {mark = "*", opacity = .8, color = colors[1]},
         "2" = {mark = "*", opacity = .8, color = colors[2]},
         "3" = {mark = "*", opacity = .8, color = colors[4]},
         "4" = {mark = "*", opacity = .8, color = colors[5]},
        }
   },
       Table({x = "loss", y = "xnorm", meta = "mineigvalsclass"},
             df[randperm(nrow(df)), ["loss", "xnorm", "mineigvalsclass"]]
            )
      ))

@pgf Axis({xmode = "log", xlabel = "loss", ylabel = "sim"},
          Plot({"scatter",
                "only marks"},
               Table({x = "loss", y = "largest_pairwise_sim"},
                     df[df.infty, ["loss", "largest_pairwise_sim"]])
              )
         )

@pgf Axis({xmode = "log", ymode = "log", xlabel = "loss", ylabel = "xnorm"},
          Plot({"scatter",
        "only marks",
        "scatter src" = "explicit symbolic",
        "scatter/classes" =
        {
         "0" = {mark = "*", opacity = .8, color = colors[1]},
         "1" = {mark = "*", opacity = .8, color = colors[4]},
        }
   },
       Table({x = "loss", y = "xnorm", meta = "on_saddle"},
             df[randperm(nrow(df)), ["loss", "xnorm", "on_saddle"]]
            )
      ))

@pgf Axis({xmode = "log", ymode = "log", xlabel = "loss", ylabel = "gradnorm"},
          Plot({"scatter",
        "only marks",
        "scatter src" = "explicit symbolic",
        "scatter/classes" =
        {
         "0" = {mark = "*", opacity = .8, color = colors[1]},
         "1" = {mark = "*", opacity = .8, color = colors[4]},
        }
   },
       Table({x = "loss", y = "gnorminf_reg", meta = "infty"},
             df[randperm(nrow(df)), ["loss", "gnorminf_reg", "infty"]]
            )
      ),
              Plot({
                    "only marks",
                    mark = "x",
                    mark_options={black, scale=1.5}
               },
                   Table({x = "loss", y = "gnorminf_reg"},
                         df[df.success_iter .== 0, ["loss", "gnorminf_reg"]]
                        )
                  ),
         )

@pgf Axis({xmode = "log", ymode = "log", xlabel = "smallest pairwise dist", ylabel = "sm pairwise sim"},
          Plot({"scatter",
        "only marks",
        "scatter src" = "explicit symbolic",
        "scatter/classes" =
        {
         "2" = {mark = "*", opacity = .8, color = colors[1]},
         "4" = {mark = "*", opacity = .8, color = colors[3]},
         "8" = {mark = "*", opacity = .8, color = colors[5]},
        }
   },
       Table({x = "smallest_pairwise_dist", y = "sm_pairwise_sim", meta = "k"},
             df[randperm(nrow(df)), ["smallest_pairwise_dist", "sm_pairwise_sim", "k"]]
            )
      ),
              Plot({
                    "only marks",
                    mark = "x",
                    mark_options={black, scale=1.5}
               },
                   Table({x = "smallest_pairwise_dist", y = "sm_pairwise_sim"},
                         df[df.success_iter .== 0, ["smallest_pairwise_dist", "sm_pairwise_sim"]]
                        )
                  ),
         )




globalminexample = df[(df.seed .== 3) .& (df.k .== "4") .& (df.activation_function .== "softplus") .& (df.ρ .== "4"), :]
globalminexample2 = df[(df.seed .== 15) .& (df.k .== "4") .& (df.activation_function .== "softplus") .& (df.ρ .== "4"), :]
localminexample = df[(df.seed .== 22) .& (df.k .== "4") .& (df.activation_function .== "softplus") .& (df.ρ .== "4"), :]

using Random: randperm
f = @pgf Axis({xmode = "log",
               ymode = "log",
               xlabel = "mean squared error",
               ylabel = raw"$\|\nabla L\|_\infty$",
               title = "",
#                ymax = 1e-4, ymin = 5e-19,
               legend_pos = "outer north east",
               font = "\\footnotesize"
              },
              ["\\draw[gray, ->, opacity = .3] ($(df.ode_loss[i]), $(df.ode_gnorminf_reg[i])) -- ($(df.loss[i]), $(df.gnorminf_reg[i]));" for i in 1:nrow(df)]...,
              Plot({"scatter",
                    "only marks",
                    "scatter src" = "explicit symbolic",
                    "scatter/classes" =
                    {
                     "1" = {mark = "*", opacity = .8, color = colors[1]},
                     "2" = {mark = "*", opacity = .8, color = colors[2]},
                     "3" = {mark = "*", opacity = .8, color = colors[4]},
                     "4" = {mark = "*", opacity = .8, color = colors[5]},
                    }
               },
                   Table({x = "loss", y = "gnorminf_reg", meta = "mineigvalsclass"},
                         df[randperm(nrow(df)), ["loss", "gnorminf_reg", "mineigvalsclass"]]
                        )
                  ),
              Plot({
                    "only marks",
                    mark = "x",
                    mark_options={black, scale=1.5}
               },
                   Table({x = "loss", y = "gnorminf_reg"},
                         df[df.success_iter .== 0, ["loss", "gnorminf_reg"]]
                        )
                  ),
              Legend([raw"$-10^{-4} < \lambda_\mathrm{min} < -10^{-8}$",
                      raw"$-10^{-8}\leq\lambda_\mathrm{min} < 0$",
                      raw"$0\leq\lambda_\mathrm{min} < 10^{-8}$",
                      raw"$10^{-8}\leq\lambda_\mathrm{min}$",
                      "not converged",
                     ])
             )

pgfsave("fixed_point.tikz", f)

f2 = @pgf Axis({xmode = "log",
               ymode = "log",
               xlabel = "mean squared error",
               ylabel = raw"$\|\nabla L\|_\infty$",
               title = "",
               set_layers, mark_layer = "axis tick labels",
#                ymax = 1e-4, ymin = 5e-18,
               legend_pos = "outer north east",
               font = "\\footnotesize"
              },
              Plot({"scatter",
                    "only marks",
                    "scatter src" = "explicit symbolic",
                    "scatter/classes" =
                    {
                     "2-1" = {mark = "o", very_thick, opacity = .8, color = colors[2]},
                     "2-2" = {mark = "+", very_thick, opacity = .8, color = colors[2]},
                     "2-4" = {mark = "x", very_thick, opacity = .8, color = colors[2]},
                     "4-1" = {mark = "o", very_thick, opacity = .8, color = colors[3]},
                     "4-2" = {mark = "+", very_thick, opacity = .8, color = colors[3]},
                     "4-4" = {mark = "x", very_thick, opacity = .8, color = colors[3]},
                     "8-1" = {mark = "o", very_thick, opacity = .8, color = colors[4]},
                     "8-2" = {mark = "+", very_thick, opacity = .8, color = colors[4]},
                     "8-4" = {mark = "x", very_thick, opacity = .8, color = colors[4]},
                    }
               },
                   Table({x = "loss", y = "gnorminf_reg", meta = "kind"},
                         df[randperm(nrow(df)), ["loss", "gnorminf_reg", "kind"]]
                        )
                  ),
              Plot({
                    "only marks",
                    mark = "x",
                    mark_options={black, scale=1}
               },
                   Table({x = "loss", y = "gnorminf_reg"},
                         df[df.success_iter .== 0, ["loss", "gnorminf_reg"]]
                        )
                  ),
#               "\\node (globalstart) at (1e-25, 1e-10) {global?}; \\node[inner sep = 1] (globalend) at ($(globalminexample.loss[1]), $(globalminexample.gnorminf_reg[1])) {};\\draw[very thick, ->] (globalstart) -- (globalend);",
#               "\\node[inner sep = 1] (globalend) at ($(globalminexample2.loss[1]), $(globalminexample2.gnorminf_reg[1])) {};\\draw[very thick, ->] (globalstart) -- (globalend);",
#               "\\node (localstart) at (1e-18, 5e-8) {local}; \\node[inner sep = 0] (localend) at ($(localminexample.loss[1]), $(localminexample.gnorminf_reg[1])) {};\\draw[very thick, ->, shorten >= -1pt] (localstart) -- (localend);",
#               HLine({dashed}, 1e-13),
              Legend([raw"$D^0 = D^{1*} = 2, D^1 = 2$",
                      raw"$D^0 = D^{1*} = 2, D^1 = 4$",
                      raw"$D^0 = D^{1*} = 2, D^1 = 8$",
                      raw"$D^0 = D^{1*} = 4, D^1 = 4$",
                      raw"$D^0 = D^{1*} = 4, D^1 = 8$",
                      raw"$D^0 = D^{1*} = 4, D^1 = 16$",
                      raw"$D^0 = D^{1*} = 8, D^1 = 8$",
                      raw"$D^0 = D^{1*} = 8, D^1 = 16$",
                      raw"$D^0 = D^{1*} = 8, D^1 = 32$",
                      "not converged",
                     ])
             )

pgfsave("fixed_point2b.pdf", f2)

pgfsave("fixed_point2.tikz", f2)

import MLPGradientFlow: pairwise, similarity
function find_anti_correlated(row)
    k = parse(Int, row.k)
    _, _, xt = setup(seed = row.seed,
                       Din = k,
                       k = k,
                       r = k*parse(Int, row.ρ))
    sol = params(row.res2["x"])
    sims = pairwise(similarity, sol.w1, xt.w1)
    return minimum(sims) < -.99
#     teacher_found = sims .> .999
#     sum(teacher_found) ≥ k
end
df.anticorr = find_anti_correlated.(eachrow(df))
# df.teacher_found = find_anti_correlated.(eachrow(df))

results = DataFrame(KenCarp58 = [],
                    Adam = [],
                    Newton = [],
                    SLSQP = [],
                    BFGS = [],
                    LBFGS = [],
                    r = Int[]
                   )
for seed in 1:10, r in (8, 64)
    net, x = setup(seed = seed, Din = r÷4, k = r÷4, r = r)
    res1 = train(net, x, alg = KenCarp58(), maxtime_ode = 360, maxiterations_optim = 0)
    res2 = train(net, x, alg = Adam(1e-3), maxtime_ode = 360, maxiterations_optim = 0)
    res3 = train(net, x, optim_solver = NewtonTrustRegion(),
                 maxiterations_ode = 0, maxtime_optim = 360, maxiterations_optim = 10^9)
    res4 = train(net, x, optim_solver = :LD_SLSQP, maxiterations_optim = 10^9,
                 maxiterations_ode = 0, maxtime_optim = 360)
    res5 = train(net, x, maxiterations_ode = 0, maxtime_optim = 360,
                 optim_solver = BFGS(), maxiterations_optim = 10^9)
    res6 = train(net, x, maxiterations_ode = 0, maxtime_optim = 360,
                 optim_solver = :LD_LBFGS, maxiterations_optim = 10^9)
    push!(results, [res1, res2,
                    res3, res4,
                    res5, res6,
                    r])
end
serialize("loss.dat", results)

function prepare_plots(results; extractor = x -> x["loss"])
    DataFrame(x = randn(6*nrow(results))/10 .+ repeat(1:6, inner = nrow(results)),
              y = vcat(extractor.(results.Adam),
                       extractor.(results.LBFGS),
                       extractor.(results.KenCarp58),
                       extractor.(results.Newton),
                       extractor.(results.BFGS),
                       extractor.(results.SLSQP),
                    ))
end
res1 = prepare_plots(results[results.r .== 8, :])
res2 = prepare_plots(results[results.r .== 64, :])

function plot_loss(res, title; ymin = 1e-18, ymax = 1e-1)
    @pgf Axis({ymode = "log", ymin = ymin, ymax = ymax,
               font = "\\small",
#                width = "10cm",
#                height = "5cm",
               ylabel = "mean squared error",
               xticklabel_style = {rotate = 40},
               xtick = 1:6,
               xticklabels = {"Adam", "LBFGS", "KenCarp", "Newton", "BFGS", "SLSQP"},
               xlabel = "method", title = title},
              Plot({"only marks",
                    color = "black",
                   },
                   Coordinates(res.x, res.y))
             )
end
f = plot_loss(res1, "33 parameters")
pgfsave("loss_small.tikz", f)
f = plot_loss(res2, "1153 parameters", ymin = 1e-5, ymax = 1)
pgfsave("loss_large.tikz", f)
