using Ipopt
using MathProgBase
using JuMP

include("hs006.jl")

# pass an AmplModel to IPOPT
nlp = JuMPNLPModel(hs006())
show(nlp.meta)
print(nlp.meta)
model = NLPtoMPB(nlp, IpoptSolver())
@assert isa(model, Ipopt.IpoptMathProgModel)
MathProgBase.optimize!(model)
@assert MathProgBase.getobjval(model) ≈ 0.0