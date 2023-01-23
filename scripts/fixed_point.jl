using Distributed, Pkg
Pkg.activate(joinpath(@__DIR__, "."))
using MLPGradientFlow
const activation_function = getproperty(MLPGradientFlow, Meta.parse(ARGS[1]))
addprocs(48, exeflags="--project=$(joinpath(@__DIR__, "."))")
@everywhere begin
include(joinpath(@__DIR__, "helper.jl"))

using Optim, OrdinaryDiffEq


function converge_to_fixed_point(net, x;
                                 max_iters = 30, maxiterations_per_iter = 10^5,
                                 maxtime_per_iter = 120,
                                 minimal_abs_drop = 0,
                                 minimal_rel_drop = 0,
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
        if latest_drop ≤ minimal_abs_drop || latest_drop/res2["loss"] ≤ minimal_rel_drop
            success_iter = iter
            break
        end
        oldl = res2["loss"]
        init = params(res2["x"])
    end
    res, res2, (success_iter, drops)
end
end

settings = collect(Iterators.product(1:30, (2, 4, 8), (1, 2, 4)))

@sync @distributed for (seed, k, ρ) in settings
    @show seed k ρ
    net, x, xt = setup(seed = seed, Din = k, k = k, r = k*ρ, f = activation_function)
    res = converge_to_fixed_point(net, x,
                                  maxtime_per_iter = 2*3600,
                                  maxtime_ode = 2*3600,
                                  maxtime_optim = 2*3600,
                                  maxiterations_per_iter = 10^4,
                                  maxiterations_ode = 10^4,
                                  maxiterations_optim = 10^4,
                                  maxnorm = 5*10^3,
                                  g_tol = 1e-16,
                                 )
    serialize("fp2-$activation_function-$seed-$k-$ρ.dat", (; seed, k, ρ, res, xt))
end
# 
# function getnorms(net, x)
#     N = size(net.input, 2)
#     dx = gradient(net, x)
#     dx ./= N
#     gnorm = sqrt(sum(abs2, dx))
#     gnorminf = maximum(abs, dx)
#     nx = sum(abs2, x)/2
#     c = 5*10^3
#     if nx > c
#         dx .+= (nx - c)*x/N
#     end
#     gnorm_reg = sqrt(sum(abs2, dx))
#     gnorminf_reg = maximum(abs, dx)
#     (; gnorm, gnorminf, gnorm_reg, gnorminf_reg)
# end
# df = DataFrame(seed = Int[], k = String[], ρ = String[],
#                success_iter = Int[],
#                drops = Float64[],
#                ode_loss = Float64[],
#                loss = Float64[],
#                loss1 = Float64[],
#                ode_gnorminf_reg = Float64[],
#                gnorminf_reg = Float64[],
#                mineigval = Float64[],
#                gnorm = Float64[],
#                gnorm_reg = Float64[],
#                gnorminf = Float64[],
#                activation_function = String[],
#                res = [], res2 = [],
#               )
# for (seed, k, ρ) in settings
#     for activation in (g, softplus)
#         f = "fp-$activation-$seed-$k-$ρ.dat"
#         isfile(f) || continue
#         net, x, xt = setup(seed = seed, Din = k, k = k, r = k*ρ, f = activation)
#         _, _, _, res, _ = deserialize(f)
#         sol = params(res[2]["x"])
#         gnorm, gnorminf, gnorm_reg, gnorminf_reg = getnorms(net, sol)
#         ode_gnorm, ode_gnorminf, ode_gnorm_reg, ode_gnorminf_reg = getnorms(net, params(res[1]["ode_x"]))
#         if isnan(sum(sol))
#             mineigval = NaN
#         else
#             mineigval = first(first(hessian_spectrum(net, sol)))
#         end
#         push!(df, [seed, "$k", "$ρ", res[3][1], res[3][2][end],
#                    res[1]["ode_loss"],
#                    res[2]["loss"],
#                    res[1]["loss"],
#                    ode_gnorminf_reg,
#                    gnorminf_reg,
#                    mineigval,
#                    gnorm,
#                    gnorm_reg,
#                    res[2]["gnorm"],
#                    "$activation",
#                    res[1], res[2]])
#     end
# end
# df.mineigvalsclass = (x -> x < -1e-9 ? 1 :
#                       x < 0 ? 2 :
#                       x < 1e-9 ? 3 : 4).(df.mineigval)
# minimum(df.mineigval) > -1e-8
# 
# globalminexample = df[(df.seed .== 28) .& (df.k .== "2") .& (df.activation_function .== "g") .& (df.ρ .== "2"), :]
# localminexample = df[(df.seed .== 21) .& (df.k .== "2") .& (df.activation_function .== "g") .& (df.ρ .== "4"), :]
# 
# 
# f = @pgf Axis({xmode = "log",
#                ymode = "log",
#                xlabel = "mean squared error",
#                ylabel = raw"$\|\nabla L\|_\infty$",
#                title = "",
#                ymax = 1e-2, ymin = 5e-18,
#                legend_pos = "outer north east",
#                font = "\\footnotesize"
#               },
#               ["\\draw[gray, ->, opacity = .5] ($(df.ode_loss[i]), $(df.ode_gnorminf_reg[i])) -- ($(df.loss[i]), $(df.gnorminf_reg[i]));" for i in 1:nrow(df)]...,
#               Plot({"scatter",
#                     "only marks",
#                     "scatter src" = "explicit symbolic",
#                     "scatter/classes" =
#                     {
#                      "1" = {mark = "o", mark_size = 1, color = colors[1]},
#                      "2" = {mark = "o", mark_size = 1, color = colors[2]},
#                      "3" = {mark = "o", mark_size = 1, color = colors[4]},
#                      "4" = {mark = "o", mark_size = 1, color = colors[5]},
#                     }
#                },
#                    Table({x = "loss", y = "gnorminf_reg", meta = "mineigvalsclass"},
#                          df[:, ["loss", "gnorminf_reg", "mineigvalsclass"]]
#                         )
#                   ),
#               "\\node (globalstart) at (1e-28, 1e-10) {global}; \\node[inner sep = 1] (globalend) at ($(globalminexample.loss[1]), $(globalminexample.gnorm[1])) {};\\draw[very thick, ->] (globalstart) -- (globalend);",
#               "\\node (localstart) at (1e-18, 5e-8) {local}; \\node[inner sep = 0] (localend) at ($(localminexample.loss[1]), $(localminexample.gnorm[1])) {};\\draw[very thick, ->, shorten >= -1pt] (localstart) -- (localend);",
# #               HLine({dashed}, 1e-13),
#               Legend([raw"$-10^{-8} < \lambda_\mathrm{min} < -10^{-9}$",
#                       raw"$-10^{-9}\leq\lambda_\mathrm{min} < 0$",
#                       raw"$0\leq\lambda_\mathrm{min} < 10^{-9}$",
#                       raw"$10^{-9}\leq\lambda_\mathrm{min}$",
#                      ])
#              )
# pgfsave("fixed_point.tikz", f)
# 
# f2 = @pgf Axis({xmode = "log",
#                ymode = "linear",
#                xlabel = "loss",
#                ylabel = raw"$\|\nabla L\|_\infty$",
#                title = "",
# #                ymax = 1e-2, ymin = 5e-18,
#               },
#               Plot({"scatter",
#                     "only marks",
#                     "scatter src" = "explicit symbolic",
#                     "scatter/classes" =
#                     {
#                      "1" = {mark = "*", color = colors[1]},
#                      "2" = {mark = "*", color = colors[2]},
#                      "4" = {mark = "*", color = colors[3]},
#                     }
#                },
#                    Table({x = "loss", y = "mineigval", meta = "ρ"},
#                          df[df.mineigval .> 0, 1:12]
#                         )
#                   ),
#              )
# 
# 
# # results = DataFrame(KenCarp58 = [],
# #                     Adam = [],
# #                     Newton = [],
# #                     SLSQP = [],
# #                     BFGS = [],
# #                     LBFGS = [],
# #                     r = Int[]
# #                    )
# # for seed in 1:10, r in (8, 64)
# #     net, x = setup(seed = seed, Din = r÷4, k = r÷4, r = r)
# #     res1 = train(net, x, alg = KenCarp58(), maxtime_ode = 360, maxiterations_optim = 0)
# #     res2 = train(net, x, alg = Adam(1e-3), maxtime_ode = 360, maxiterations_optim = 0)
# #     res3 = train(net, x, optim_solver = NewtonTrustRegion(),
# #                  maxiterations_ode = 0, maxtime_optim = 360, maxiterations_optim = 10^9)
# #     res4 = train(net, x, optim_solver = :LD_SLSQP, maxiterations_optim = 10^9,
# #                  maxiterations_ode = 0, maxtime_optim = 360)
# #     res5 = train(net, x, maxiterations_ode = 0, maxtime_optim = 360,
# #                  optim_solver = BFGS(), maxiterations_optim = 10^9)
# #     res6 = train(net, x, maxiterations_ode = 0, maxtime_optim = 360,
# #                  optim_solver = :LD_LBFGS, maxiterations_optim = 10^9)
# #     push!(results, [res1, res2,
# #                     res3, res4,
# #                     res5, res6,
# #                     r])
# # end
# serialize("loss.dat", results)
# 
# net, x, xt = setup(seed = 128, Din = 2, k = 2, r = 8, f = g)
# res, res2, success_iter = converge_to_fixed_point(net, x. maxtime_optim = 300)
# 
# res = train(net, x, optim_solver = :LD_SLSQP, maxiterations_optim = 10^9,
#             maxiterations_ode = 100, maxtime_optim = 120)
# res2 = train(net, params(res["x"]), g_tol = 1e-16,
#              maxiterations_ode = 0,
#              optim_solver = Newton(), maxiterations_optim = 10^3)
# 
# function prepare_plots(results; extractor = x -> x["loss"])
#     DataFrame(x = randn(6*nrow(results))/10 .+ repeat(1:6, inner = nrow(results)),
#               y = vcat(extractor.(results.Adam),
#                        extractor.(results.LBFGS),
#                        extractor.(results.KenCarp58),
#                        extractor.(results.Newton),
#                        extractor.(results.BFGS),
#                        extractor.(results.SLSQP),
#                     ))
# end
# res1 = prepare_plots(results[results.r .== 8, :])
# res2 = prepare_plots(results[results.r .== 64, :])
# 
# function plot_loss(res, title; ymin = 1e-18, ymax = 1e-1)
#     @pgf Axis({ymode = "log", ymin = ymin, ymax = ymax,
#                font = "\\small",
# #                width = "10cm",
# #                height = "5cm",
#                ylabel = "mean squared error",
#                xticklabel_style = {rotate = 40},
#                xtick = 1:6,
#                xticklabels = {"Adam", "LBFGS", "KenCarp", "Newton", "BFGS", "SLSQP"},
#                xlabel = "method", title = title},
#               Plot({"only marks",
#                     color = "black",
#                    },
#                    Coordinates(res.x, res.y))
#              )
# end
# f = plot_loss(res1, "33 parameters")
# pgfsave("loss_small.tikz", f)
# f = plot_loss(res2, "1153 parameters", ymin = 1e-5, ymax = 1)
# pgfsave("loss_large.tikz", f)
