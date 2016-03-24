using JuMP
using MathProgBase

export JuMPNLPModel,
       reset!,
       obj, grad, grad!,
       cons, cons!, jac_coord, jac, jprod, jprod!, jtprod, jtprod!,
       hess_coord, hess, hprod, hprod!

type ModelReader <: MathProgBase.AbstractMathProgSolver
end

type MathProgModel <: MathProgBase.AbstractMathProgModel
  eval :: @compat Union{JuMPNLPEvaluator, Void}
  numVar :: Int
  numConstr :: Int
  x :: Vector{Float64}
  y :: Vector{Float64}
  lvar :: Vector{Float64}
  uvar :: Vector{Float64}
  lcon :: Vector{Float64}
  ucon :: Vector{Float64}
  sense :: Symbol
  status :: Symbol
end

MathProgBase.NonlinearModel(solver :: ModelReader) = MathProgModel(nothing,
                                                                   0,
                                                                   0,
                                                                   Float64[],
                                                                   Float64[],
                                                                   Float64[],
                                                                   Float64[],
                                                                   Float64[],
                                                                   Float64[],
                                                                   :Min,
                                                                   :Uninitialized);

function MathProgBase.loadproblem!(m :: MathProgModel,
                                   numVar, numConstr,
                                   l, u, lb, ub,
                                   sense,
                                   eval :: MathProgBase.AbstractNLPEvaluator)

  # TODO: :JacVec is not yet available.
  # [:Grad, :Jac, :JacVec, :Hess, :HessVec, :ExprGraph]
  MathProgBase.initialize(eval, [:Grad, :Jac, :Hess, :HessVec, :ExprGraph])
  m.numVar = numVar
  m.numConstr = numConstr
  m.x = zeros(numVar)
  m.y = zeros(numConstr)
  m.eval = eval
  m.lvar = l
  m.uvar = u
  m.lcon = lb
  m.ucon = ub
  m.sense = sense
end

MathProgBase.setwarmstart!(m :: MathProgModel, x) = (m.x = x)
MathProgBase.status(m :: MathProgModel) = m.status
MathProgBase.getsolution(m :: MathProgModel) = m.x
MathProgBase.getobjval(m :: MathProgModel) = MathProgBase.eval_f(m.eval, m.x)

type JuMPNLPModel <: AbstractNLPModel
  meta :: NLPModelMeta
  jmodel :: Model          # JuMP internal model
  mpmodel :: MathProgModel

  counters :: Counters      # Evaluation counters.
  g :: Vector{Float64}      # Room for the objective gradient.
  hvals :: Vector{Float64}  # Room for the Lagrangian Hessian.
  hv :: Vector{Float64}     # Room for a Hessian-vector product.
  c :: Vector{Float64}      # Room for the constraints value.
  jvals :: Vector{Float64}  # Room for the constraints Jacobian.
  jv :: Vector{Float64}     # Room for a Jacobian-vector product.
  jtv :: Vector{Float64}    # Room for a transposed-Jacobian-vector product.
end

"Construct a `JuMPNLPModel` from a JuMP `Model`."
function JuMPNLPModel(jmodel :: Model)

  setSolver(jmodel, ModelReader())
  buildInternalModel(jmodel)
  mpmodel = getInternalModel(jmodel)

  nvar = mpmodel.numVar
  lvar = mpmodel.lvar
  uvar = mpmodel.uvar

  nlin = MathProgBase.numlinconstr(jmodel)        # Number of linear constraints.
  nquad = MathProgBase.numquadconstr(jmodel)      # Number of quadratic constraints.
  nnln = length(mpmodel.eval.m.nlpdata.nlconstr)  # Number of nonlinear constraints.
  ncon = mpmodel.numConstr                        # Total number of constraints.
  lcon = mpmodel.lcon
  ucon = mpmodel.ucon

  jrows, jcols = MathProgBase.jac_structure(mpmodel.eval)
  hrows, hcols = MathProgBase.hesslag_structure(mpmodel.eval)
  nnzj = length(jrows)
  nnzh = length(hrows)

  meta = NLPModelMeta(nvar,
                      x0=mpmodel.x,
                      lvar=lvar,
                      uvar=uvar,
                      ncon=ncon,
                      y0=zeros(ncon),
                      lcon=lcon,
                      ucon=ucon,
                      nnzj=nnzj,
                      nnzh=nnzh,
                      lin=collect(1:nlin),  # linear constraints appear first in JuMP
                      nln=collect(nlin+1:ncon),
                      minimize=(mpmodel.sense == :Min),
                      islp=MathProgBase.isobjlinear(mpmodel.eval) & (nlin == ncon),
                      )

  return JuMPNLPModel(meta,
                   jmodel,
                   mpmodel,
                   Counters(),
                   zeros(nvar),  # g
                   zeros(nnzh),  # hvals
                   zeros(nvar),  # hv
                   zeros(ncon),  # c
                   zeros(nnzj),  # jvals
                   zeros(ncon),  # jv
                   zeros(nvar),  # jtv
                   )
end

import Base.show
show(nlp :: JuMPNLPModel) = show(nlp.jmodel)

"Reset evaluation counters in `nlp`"
function reset!(nlp :: JuMPNLPModel)
  reset!(nlp.counters)
  return nlp
end

"Evaluate the objective function of `nlp` at `x`."
function obj(nlp :: JuMPNLPModel, x :: Array{Float64})
  nlp.counters.neval_obj += 1
  return MathProgBase.eval_f(nlp.mpmodel.eval, x)
end

# TODO: Move g out of JuMPNLPModel?
"Evaluate the gradient of the objective function at `x`."
function grad(nlp :: JuMPNLPModel, x :: Array{Float64})
  nlp.counters.neval_grad += 1
  MathProgBase.eval_grad_f(nlp.mpmodel.eval, nlp.g, x)
  return nlp.g
end

"Evaluate the gradient of the objective function at `x` in place."
function grad!(nlp :: JuMPNLPModel, x :: Array{Float64}, g :: Array{Float64})
  nlp.counters.neval_grad += 1
  MathProgBase.eval_grad_f(nlp.mpmodel.eval, g, x)
  return g
end

# TODO: Move c out of JuMPNLPModel?
"Evaluate the constraints at `x`."
function cons(nlp :: JuMPNLPModel, x :: Array{Float64})
  nlp.counters.neval_cons += 1
  MathProgBase.eval_g(nlp.mpmodel.eval, nlp.c, x)
  return nlp.c
end

"Evaluate the constraints at `x` in place."
function cons!(nlp :: JuMPNLPModel, x :: Array{Float64}, c :: Array{Float64})
  nlp.counters.neval_cons += 1
  MathProgBase.eval_g(nlp.mpmodel.eval, c, x)
  return c
end

"Evaluate the constraints Jacobian at `x` in sparse coordinate format."
function jac_coord(nlp :: JuMPNLPModel, x :: Array{Float64})
  nlp.counters.neval_jac += 1
  MathProgBase.eval_jac_g(nlp.mpmodel.eval, nlp.jvals, x)
  return (nlp.mpmodel.eval.jac_I, nlp.mpmodel.eval.jac_J, nlp.jvals)
end

"Evaluate the constraints Jacobian at `x` as a sparse matrix."
function jac(nlp :: JuMPNLPModel, x :: Array{Float64})
  return sparse(jac_coord(nlp, x)..., nlp.meta.ncon, nlp.meta.nvar)
end

"Evaluate the Jacobian-vector product at `x`."
function jprod(nlp :: JuMPNLPModel, x :: Array{Float64}, v :: Array{Float64})
  nlp.counters.neval_jprod += 1
  MathProgBase.eval_jac_prod(nlp.mpmodel.eval, nlp.jv, x, v)
  return nlp.jv
end

"Evaluate the Jacobian-vector product at `x` in place."
function jprod!(nlp :: JuMPNLPModel, x :: Array{Float64}, v :: Array{Float64}, jv ::
  Array{Float64})
  nlp.counters.neval_jprod += 1
  MathProgBase.eval_jac_prod(nlp.mpmodel.eval, jv, x, v)
  return jv
end

"Evaluate the transposed-Jacobian-vector product at `x`."
function jtprod(nlp :: JuMPNLPModel, x :: Array{Float64}, v :: Array{Float64})
  nlp.counters.neval_jtprod += 1
  MathProgBase.eval_jac_prod_t(nlp.mpmodel.eval, nlp.jtv, x, v)
  return nlp.jtv
end

"Evaluate the transposed-Jacobian-vector product at `x` in place."
function jtprod!(nlp :: JuMPNLPModel, x :: Array{Float64}, v :: Array{Float64}, jtv ::
  Array{Float64})
  nlp.counters.neval_jtprod += 1
  MathProgBase.eval_jac_prod_t(nlp.mpmodel.eval, jtv, x, v)
  return jtv
end

"""Evaluate the Lagrangian Hessian at `(x,y)` in sparse coordinate format.
Only the lower triangle is returned.
"""
function hess_coord(nlp :: JuMPNLPModel, x :: Array{Float64}, y :: Array{Float64})
  nlp.counters.neval_hess += 1
  MathProgBase.eval_hesslag(nlp.mpmodel.eval, nlp.hvals, x, 1.0, y)
  return (nlp.mpmodel.eval.hess_I, nlp.mpmodel.eval.hess_J, nlp.hvals)
end

"""Evaluate the objective Hessian at `x` in sparse coordinate format.
Only the lower triangle is returned.
"""
function hess_coord(nlp :: JuMPNLPModel, x :: Array{Float64})
  return hess_coord(nlp, x, zeros(nlp.meta.ncon))
end

"""Evaluate the Lagrangian Hessian at `(x,y)` as a sparse matrix.
Only the lower triangle is returned.
"""
function hess(nlp :: JuMPNLPModel, x :: Array{Float64}, y :: Array{Float64})
  return sparse(hess_coord(nlp, x, y)..., nlp.meta.nvar, nlp.meta.nvar)
end

"""Evaluate the objective Hessian at `x` as a sparse matrix.
Only the lower triangle is returned.
"""
function hess(nlp :: JuMPNLPModel, x :: Array{Float64})
  return sparse(hess_coord(nlp, x)..., nlp.meta.nvar, nlp.meta.nvar)
end

# TODO: Move hv out of JuMPNLPModel
"Evaluate the product of the Lagrangian Hessian at `(x,y)` with the vector `v`."
function hprod(nlp :: JuMPNLPModel, x :: Array{Float64}, y :: Array{Float64}, v :: Array{Float64})
  nlp.counters.neval_hprod += 1
  MathProgBase.eval_hesslag_prod(nlp.mpmodel.eval, nlp.hv, x, v, 1.0, y)
  return nlp.hv
end

"Evaluate the product of the Lagrangian Hessian at `(x,y)` with the vector `v` in place."
function hprod!(nlp :: JuMPNLPModel, x :: Array{Float64}, y :: Array{Float64}, v :: Array{Float64}, hv :: Array{Float64})
  nlp.counters.neval_hprod += 1
  MathProgBase.eval_hesslag_prod(nlp.mpmodel.eval, hv, x, v, 1.0, y)
  return hv
end

"Evaluate the product of the objective Hessian at `(x,y)` with the vector `v`."
function hprod(nlp :: JuMPNLPModel, x :: Array{Float64}, v :: Array{Float64})
  return hprod(nlp, x, zeros(nlp.meta.ncon), v)
end

"Evaluate the product of the objective Hessian at `(x,y)` with the vector `v` in place."
function hprod!(nlp :: JuMPNLPModel, x :: Array{Float64}, v :: Array{Float64}, hv :: Array{Float64})
  return hprod!(nlp, x, zeros(nlp.meta.ncon), v, hv)
end