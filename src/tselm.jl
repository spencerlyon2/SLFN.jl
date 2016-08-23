"""

#### References

Two-stage extreme learning machine for regression.

Yuan Lan, Yeng Chai Soh, and Guang-Bin Huang.

Neurocomputing, 2010 vol. 73 (16-18) pp. 3028-3038.

http://linkinghub.elsevier.com/retrieve/pii/S0925231210003401
"""
type TSELM{TA<:AbstractActivation,TN<:AbstractNodeInput,TV<:AbstractArray{Float64}} <: AbstractSLFN
    p::Int  # Number of training points
    q::Int  # Dimensionality of function domain
    ngroup::Int  # number of groups
    npg::Int  # nodes per group
    Lmax::Int  # maximum number of neurons
    activation::TA
    neuron_type::TN
    At::Matrix{Float64}
    b::Vector{Float64}
    β::TV

    function TSELM(p::Int, q::Int, ngroup::Int, npg::Int, Lmax::Int, activation::TA,
                   neuron_type::TN)
        WARNINGS[1] && warn("This routine is experimental!!")
        new(p, q, ngroup, npg, Lmax, activation, neuron_type)
    end
end


function TSELM{TA<:AbstractActivation,
               TN<:AbstractNodeInput,
               TV<:AbstractArray}(x::AbstractArray, t::TV; activation::TA=Sigmoid(),
                                  neuron_type::TN=Linear(), Lmax::Int=size(x, 1),
                                  ngroup::Int=5,
                                  npg::Int=ceil(Int, size(x, 1)/10))
    q = size(x, 2)  # dimensionality of function domain
    p = size(x, 1)  # number of training points
    Lmax = min(p, Lmax)  # can't have more neurons than obs
    out = TSELM{TA,TN,TV}(p, q, ngroup, npg, Lmax, activation, neuron_type)
    fit!(out, x, t)
end

## helper methods
# take every other data point so that when a is something like
# a linspace we still get decent coverage of the whole domain
_split_data(a::AbstractVector) = (a[1:2:end], a[2:2:end])
_split_data(a::AbstractMatrix) = (a[1:2:end, :], a[2:2:end, :])

## API methods
isexact(elm::TSELM) = elm.p == false
input_to_node(elm::TSELM, x, Wt, d) = input_to_node(elm.neuron_type, x, Wt, d)
function hidden_out(elm::TSELM, x::AbstractArray, Wt::AbstractMatrix,
                    d::AbstractVector)
    elm.activation(input_to_node(elm, x, Wt, d))
end


function forward_selection!(elm::TSELM, x::AbstractArray, t::AbstractVector)
    # split data sets
    train_x, validate_x = _split_data(x)
    train_t, validate_t = _split_data(t)
    N = size(train_x, 1)
    N_validate = size(validate_x, 1)

    # initialize
    L = 0
    R = eye(N, N)
    A = zeros(elm.q, elm.Lmax + elm.npg)
    b = zeros(elm.Lmax + elm.npg)

    while L < elm.Lmax
        L += elm.npg
        inds = (L-elm.npg)+1:L

        # variables to hold max ΔJ and corresponding δH for this
        # batch of groups. Define empty matrices to get type stability
        ΔJ = -Inf
        ΔR = zeros(0, 0)
        Ak = zeros(0, 0)
        bk = zeros(0)

        for i in 1:elm.ngroup
            # Step 1: randomly generate hidden parameters for this group
            aiT = 2*rand(elm.q, elm.npg) - 1  # uniform [-1, 1]
            bi = rand(elm.npg)                # uniform [0, 1]

            # Step 2: generate the hidden output for this group
            δHi = hidden_out(elm, train_x, aiT, bi)

            # Step 3: compute the contribution of this group to cost function
            # TODO: sometimes (δHi'R*δHi) is singular. I can loop over above until
            #       it works
            ΔRi = (R*δHi)*((δHi'R*δHi) \ (δHi'R'))
            ΔJi = dot(train_t, ΔRi*train_t)

            # Step 4: keep this group if it is the best we've seen so far
            if ΔJi > ΔJ
                ΔR = ΔRi
                Ak = aiT
                bk = bi
            end
        end

        # Step 5: Update hidden node parameters (A, b), R matrix, H
        A[:, inds] = Ak
        b[inds] = bk
        R -= ΔR
    end

    # Step 6: Find the optimal number of neurons pstar
    pstar = 0
    fpe_min = Inf
    for p in elm.ngroup:elm.ngroup:elm.Lmax
        Hp = hidden_out(elm, validate_x, A[:, 1:p], b[1:p])
        βp = Hp \ validate_t
        SSEp = norm(validate_t - Hp*βp, 2)
        fpe = SSEp/N_validate * (N_validate+p)/(N_validate-p)

        if fpe < fpe_min
            fpe_min = fpe
            pstar = p
        end
    end

    # Step 7: Rebuild the net with the selected neurons and fit
    #         with entire training set
    elm.At = A[:, 1:pstar]
    elm.b = b[1:pstar]
    H = hidden_out(elm, x, elm.At, elm.b)
    elm.β = H \ t

    elm, H
end

function backward_elimination!(elm::TSELM, x::AbstractArray, t::AbstractVector,
                               H::AbstractMatrix)
    # TODO: come back to this
    return
    pstar = size(elm.At, 2)
    Hr = copy(H)
    Hpstar = H[:, pstar]
    N = size(H, 1)

    y = H*elm.β

    # Step 1: Compute press1 for all nodes
    press1 = zeros(Float64, pstar -1)
    for k in pstar-1:-1:1
        copy!(Hr, H)
        Hk = view(H, :, k)
        Hr[:, pstar] = Hk
        Hr[:, k] = Hpstar

        ϵ = y - Hr*elm.β
        M = inv(Hr'Hr)

        for i in 1:N
            hri = Hr[i, :]
            ϵi = ϵ[i] / (1 - dot(hri, M*hri))
            press1[k] += ϵi^2
        end
        press1[k] /= N

    end

end

function fit!(elm::TSELM, x::AbstractArray, t::AbstractVector)
    elm, H = forward_selection!(elm, x, t)
    backward_elimination!(elm, x, t, H)
    elm
end

function (elm::TSELM)(y′::AbstractArray)
    @assert size(y′, 2) == elm.q "wrong input dimension"
    return hidden_out(elm, y′, elm.At, elm.b) * elm.β
end

function Base.show{TA,TN}(io::IO, elm::TSELM{TA,TN})
    s =
    """
    TSELM with
      - $(TA) Activation function
      - $(TN) Neuron type
      - $(elm.q) input dimension(s)
      - $(size(elm.At, 2)) neuron(s)
      - $(elm.p) training point(s)
      - Algorithm parameters:
          - $(elm.ngroup) trials per group
          - $(elm.npg) neurons per group
          - $(elm.Lmax) max neurons
    """
    print(io, s)
end
