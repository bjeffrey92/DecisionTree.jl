# The code in this file is a small port from scikit-learn's and numpy's
# library which is distributed under the 3-Clause BSD license.
# The rest of DecisionTree.jl is released under the MIT license.

# written by Poom Chiarawongse <eight1911@gmail.com>

module treeregressor
include("../util.jl")

import Random
import Distributions
import StatsBase
export fit

mutable struct NodeMeta{S}
    l::NodeMeta{S}  # right child
    r::NodeMeta{S}  # left child
    label::Float64      # most likely label
    feature::Int          # feature used for splitting
    threshold::S            # threshold value
    is_leaf::Bool
    depth::Int
    region::UnitRange{Int} # a slice of the samples used to decide the split of the node
    features::Vector{Int}    # a list of features not known to be constant
    split_at::Int            # index of samples
    parent_features::Vector{Int} # features that parent nodes in the tree are split on
    function NodeMeta{S}(features::Vector{Int}, region::UnitRange{Int}, depth::Int, parent_features::Vector{Int}) where {S}
        node = new{S}()
        node.depth = depth
        node.region = region
        node.features = features
        node.is_leaf = false
        node.parent_features = parent_features
        node
    end
end

struct Tree{S}
    root::NodeMeta{S}
    labels::Vector{Int}
end

# find an optimal split that satisfy the given constraints
# (max_depth, min_samples_split, min_purity_increase)
function _split!(
    X::AbstractMatrix{S}, # the feature array
    Y::AbstractVector{Float64}, # the label array
    W::AbstractVector{U},
    node::NodeMeta{S}, # the node to split    
    max_features::Int, # number of features to consider
    max_depth::Int, # the maximum depth of the resultant tree
    min_samples_leaf::Int, # the minimum number of samples each leaf needs to have
    min_samples_split::Int, # the minimum number of samples in needed for a split
    min_purity_increase::Float64, # minimum purity needed for a split
    indX::AbstractVector{Int}, # an array of sample indices,
    # we split using samples in indX[node.region]
    # the two arrays below are given for optimization purposes    
    Xf::AbstractVector{S},
    Yf::AbstractVector{Float64},
    Wf::AbstractVector{U},
    rng::Random.AbstractRNG) where {S,U}

    region = node.region
    n_samples = length(region)
    r_start = region.start - 1

    @inbounds @simd for i = 1:n_samples
        Yf[i] = Y[indX[i+r_start]]
        Wf[i] = W[indX[i+r_start]]
    end

    tssq = zero(U)
    tsum = zero(U)
    wsum = zero(U)
    @inbounds @simd for i = 1:n_samples
        tssq += Wf[i] * Yf[i] * Yf[i]
        tsum += Wf[i] * Yf[i]
        wsum += Wf[i]
    end

    node.label = tsum / wsum
    if (
        min_samples_leaf * 2 > n_samples ||
        min_samples_split > n_samples ||
        max_depth <= node.depth
        # equivalent to old_purity > -1e-7
        ||
        tsum * node.label > -1e-7 * wsum + tssq
    )
        # TODO : Add Wf[1:n_samples] to this thing
        node.is_leaf = true
        return
    end

    features = node.features
    n_features = length(features)
    best_purity = typemin(U)
    best_feature = -1
    threshold_lo = X[1]
    threshold_hi = X[1]

    indf = 1
    # the number of new constants found during this split
    n_constant = 0
    # true if every feature is constant
    unsplittable = true
    # the number of non constant features we will see if
    # only sample n_features used features
    # is a hypergeometric random variable
    total_features = size(X, 2)

    # this is the total number of features that we expect to not
    # be one of the known constant features. since we know exactly
    # what the non constant features are, we can sample at 'non_constants_used'
    # non constant features instead of going through every feature randomly.
    non_constants_used = util.hypergeometric(n_features, total_features - n_features, max_features, rng)
    @inbounds while (unsplittable || indf <= non_constants_used) && indf <= n_features
        feature = let
            indr = rand(rng, indf:n_features)
            features[indf], features[indr] = features[indr], features[indf]
            features[indf]
        end

        rssq = tssq
        lssq = zero(U)
        rsum = tsum
        lsum = zero(U)

        @simd for i = 1:n_samples
            Xf[i] = X[indX[i+r_start], feature]
        end

        # sort Yf and indX by Xf
        util.q_bi_sort!(Xf, indX, 1, n_samples, r_start)
        @simd for i = 1:n_samples
            Yf[i] = Y[indX[i+r_start]]
            Wf[i] = W[indX[i+r_start]]
        end
        nl, nr = zero(U), wsum
        # lo and hi are the indices of
        # the least upper bound and the greatest lower bound
        # of the left and right nodes respectively
        hi = 0
        last_f = Xf[1]
        is_constant = true
        while hi < n_samples
            lo = hi + 1
            curr_f = Xf[lo]
            hi = (
                lo < n_samples && curr_f == Xf[lo+1] ?
                searchsortedlast(Xf, curr_f, lo, n_samples, Base.Order.Forward) : lo
            )

            (lo != 1) && (is_constant = false)
            # honor min_samples_leaf
            if lo - 1 >= min_samples_leaf && n_samples - (lo - 1) >= min_samples_leaf
                unsplittable = false
                purity = (rsum * rsum / nr) + (lsum * lsum / nl)
                if purity > best_purity && !isapprox(purity, best_purity)
                    # will take average at the end, if possible
                    threshold_lo = last_f
                    threshold_hi = curr_f
                    best_purity = purity
                    best_feature = feature
                end
            end

            # update, lssq, rssq, lsum, rsum in the direction
            # that would require the smaller number of iterations
            if (hi << 1) < n_samples + lo # i.e., hi - lo < n_samples - hi
                @simd for i = lo:hi
                    nr -= Wf[i]
                    rsum -= Wf[i] * Yf[i]
                    rssq -= Wf[i] * Yf[i] * Yf[i]
                end
            else
                nr = rsum = rssq = zero(U)
                @simd for i = (hi+1):n_samples
                    nr += Wf[i]
                    rsum += Wf[i] * Yf[i]
                    rssq += Wf[i] * Yf[i] * Yf[i]
                end
            end
            lsum = tsum - rsum
            lssq = tssq - rssq
            nl = wsum - nr

            last_f = curr_f
        end

        # keep track of constant features to be used later.
        if is_constant
            n_constant += 1
            features[indf], features[n_constant] = features[n_constant], features[indf]
        end

        indf += 1
    end

    # no splits honor min_samples_leaf
    @inbounds if (unsplittable || best_purity - tsum * node.label < min_purity_increase * wsum)
        node.is_leaf = true
        return
    else
        # new_purity - old_purity < stop.min_purity_increase
        @simd for i = 1:n_samples
            Xf[i] = X[indX[i+r_start], best_feature]
        end

        try
            node.threshold = (threshold_lo + threshold_hi) / 2.0
        catch
            node.threshold = threshold_hi
        end
        # split the samples into two parts: ones that are greater than
        # the threshold and ones that are less than or equal to the threshold
        #                                 ---------------------
        # (so we partition at threshold_lo instead of node.threshold)
        node.split_at = util.partition!(indX, Xf, threshold_lo, region)
        node.feature = best_feature
        node.features = features[(n_constant+1):n_features]
    end

end

@inline function fork!(node::NodeMeta{S}) where {S}
    ind = node.split_at
    region = node.region
    features = node.features
    
    left_parent_features = push!(deepcopy(node.parent_features), node.feature)
    right_parent_features = deepcopy(left_parent_features)
    # no need to copy because we will copy at the end
    node.l = NodeMeta{S}(features, region[1:ind], node.depth + 1, left_parent_features)
    node.r = NodeMeta{S}(features, region[ind+1:end], node.depth + 1, right_parent_features)
end

function check_input(
    X::AbstractMatrix{S},
    Y::AbstractVector{T},
    W::AbstractVector{U},
    max_features::Int,
    max_depth::Int,
    min_samples_leaf::Int,
    min_samples_split::Int,
    min_purity_increase::Float64,
    adj::Union{AbstractMatrix{Int},Nothing} = nothing,
) where {S,T,U}
    n_samples, n_features = size(X)
    if length(Y) != n_samples
        throw("dimension mismatch between X and Y ($(size(X)) vs $(size(Y))")
    elseif length(W) != n_samples
        throw("dimension mismatch between X and W ($(size(X)) vs $(size(W))")
    elseif max_depth < -1
        throw(
            "unexpected value for max_depth: $(max_depth) (expected:" *
            " max_depth >= 0, or max_depth = -1 for infinite depth)",
        )
    elseif n_features < max_features
        throw("number of features $(n_features) is less than the number " * "of max features $(max_features)")
    elseif max_features < 0
        throw("number of features $(max_features) must be >= zero ")
    elseif min_samples_leaf < 1
        throw("min_samples_leaf must be a positive integer " * "(given $(min_samples_leaf))")
    elseif min_samples_split < 2
        throw("min_samples_split must be at least 2 " * "(given $(min_samples_split))")
    elseif !isnothing(adj) && adj != transpose(adj)
        throw("graph adjacency matrix is invalid (not symmetric)")
    end
end

"""
Search in area around each node for next node to split on
Can jump to alternative part of the graph with probability = jump_probability
"""
function _fit(
    X::AbstractMatrix{S}, # feature matrix
    Y::AbstractVector{Float64}, # labels
    W::AbstractVector{U}, # weights
    max_features::Int,
    max_depth::Int,
    min_samples_leaf::Int,
    min_samples_split::Int,
    min_purity_increase::Float64,
    feature_sample::Float64,
    rng = Random.GLOBAL_RNG::Random.AbstractRNG,
    adj::Union{AbstractMatrix{Int},Nothing} = nothing,
    sparse_adj = nothing,
    jump_probability = nothing,
    graph_steps = 1,
) where {S,U}

    n_samples, n_features = size(X)

    Yf = Array{Float64}(undef, n_samples)
    Xf = Array{S}(undef, n_samples)
    Wf = Array{U}(undef, n_samples)

    indX = collect(1:n_samples)
    feats = StatsBase.sample(
        1:n_features, 
        Int(round(feature_sample*n_features)), 
        replace = false
    )
    sort!(feats)
    root = NodeMeta{S}(feats, 1:n_samples, 0, Vector{Int}())
    stack = NodeMeta{S}[root]

    @inbounds while length(stack) > 0
        node = pop!(stack)
        if node == root || (isnothing(adj) & isnothing(sparse_adj))
            _split!(
                X,
                Y,
                W,
                node,
                max_features,
                max_depth,
                min_samples_leaf,
                min_samples_split,
                min_purity_increase,
                indX,
                Xf,
                Yf,
                Wf,
                rng,
            )
        else
            if !isnothing(jump_probability) & (jump_probability > rand(Distributions.Uniform()))
                adjacent_features = root.features
            # get the features which are next to the features already used 
            # in the tree
            elseif !isnothing(sparse_adj)
                adjacent_features = unique(
                    reduce(
                        append!,
                        (sparse_adj[i] for i in node.parent_features),
                        init=[])
                )
                for _ in 2:graph_steps
                    next_step_features = unique(
                        reduce(
                            append!,
                            (sparse_adj[i] for i in adjacent_features),
                            init=[])
                    )
                    append!(adjacent_features, next_step_features)
                    unique!(adjacent_features)
                end
            else
                features_adj = adj[unique(node.parent_features), :]
                adjacent_features = [i[2] for i in findall(!iszero, features_adj)]
            end
            adjacent_features = intersect(feats, adjacent_features)

            # if there aren't adjacent features call the node a leaf and move
            # on. Otherwise attempt to split the node on one of the adjacent
            # features
            if length(adjacent_features) == 0
                node.is_leaf = true
            else
                node.features = unique(vcat(node.parent_features, adjacent_features))
                _split!(
                    X,
                    Y,
                    W,
                    node,
                    max_features,
                    max_depth,
                    min_samples_leaf,
                    min_samples_split,
                    min_purity_increase,
                    indX,
                    Xf,
                    Yf,
                    Wf,
                    rng,
                )
            end
        end
        if !node.is_leaf
            fork!(node)
            push!(stack, node.r)
            push!(stack, node.l)
        end
    end
    return (root, indX)
end


# function _test_split(
#     X,
#     Y,
#     W,
#     node,
#     max_features,
#     max_depth,
#     min_samples_leaf,
#     min_samples_split,
#     min_purity_increase,
#     indX,
#     Xf,
#     Yf,
#     Wf,
#     rng,)
#     _split!(
#         X,
#         Y,
#         W,
#         node,
#         max_features,
#         max_depth,
#         min_samples_leaf,
#         min_samples_split,
#         min_purity_increase,
#         indX,
#         Xf,
#         Yf,
#         Wf,
#         rng,
#     )

# end


# function _fit_alt(
#     X::AbstractMatrix{S}, # feature matrix
#     Y::AbstractVector{Float64}, # labels
#     W::AbstractVector{U}, # weights
#     max_features::Int,
#     max_depth::Int,
#     min_samples_leaf::Int,
#     min_samples_split::Int,
#     min_purity_increase::Float64,
#     feature_sample::Float64,
#     rng = Random.GLOBAL_RNG::Random.AbstractRNG,
#     adj::Union{AbstractMatrix{Int},Nothing} = nothing,
#     sparse_adj = nothing,
#     graph_steps = 1,
# ) where {S,U}

#     n_samples, n_features = size(X)

#     Yf = Array{Float64}(undef, n_samples)
#     Xf = Array{S}(undef, n_samples)
#     Wf = Array{U}(undef, n_samples)

#     indX = collect(1:n_samples)
#     feats = StatsBase.sample(
#         1:n_features, 
#         Int(round(feature_sample*n_features)), 
#         replace = false
#     )
#     sort!(feats)
#     root = NodeMeta{S}(feats, 1:n_samples, 0, Vector{Int}())
#     stack = NodeMeta{S}[root]

#     @inbounds while length(stack) > 0
#         node = pop!(stack)
#         if node == root || (isnothing(adj) & isnothing(sparse_adj))
#             _split!(
#                 X,
#                 Y,
#                 W,
#                 node,
#                 max_features,
#                 max_depth,
#                 min_samples_leaf,
#                 min_samples_split,
#                 min_purity_increase,
#                 indX,
#                 Xf,
#                 Yf,
#                 Wf,
#                 rng,
#             )
#         else
#             if !isnothing(sparse_adj)
#                 adjacent_features = unique(
#                     reduce(
#                         append!,
#                         (sparse_adj[i] for i in node.parent_features),
#                         init=[])
#                 )
#                 for _ in 2:graph_steps
#                     next_step_features = unique(
#                         reduce(
#                             append!,
#                             (sparse_adj[i] for i in adjacent_features),
#                             init=[])
#                     )
#                     append!(adjacent_features, next_step_features)
#                     unique!(adjacent_features)
#                 end
#             else
#                 features_adj = adj[unique(node.parent_features), :]
#                 adjacent_features = [i[2] for i in findall(!iszero, features_adj)]
#             end
#             adjacent_features = intersect(feats, adjacent_features)

#             # if there aren't adjacent features call the node a leaf and move
#             # on. Otherwise attempt to split the node on one of the adjacent
#             # features
#             if length(adjacent_features) == 0
#                 node.is_leaf = true
#             else
#                 node.features = unique(vcat(node.parent_features, adjacent_features))
#                 _split!(
#                     X,
#                     Y,
#                     W,
#                     node,
#                     max_features,
#                     max_depth,
#                     min_samples_leaf,
#                     min_samples_split,
#                     min_purity_increase,
#                     indX,
#                     Xf,
#                     Yf,
#                     Wf,
#                     rng,
#                 )
#             end
#         end
#         if !node.is_leaf
#             fork!(node)
#             push!(stack, node.r)
#             push!(stack, node.l)
#         end
#     end
#     return (root, indX)
# end


function fit(;
    X::AbstractMatrix{S},
    Y::AbstractVector{Float64},
    W::Union{Nothing,AbstractVector{U}},
    max_features::Int,
    max_depth::Int,
    min_samples_leaf::Int,
    min_samples_split::Int,
    feature_sampling::Float64,
    min_purity_increase::Float64,
    rng = Random.GLOBAL_RNG::Random.AbstractRNG,
    adj::Union{AbstractMatrix{Int},Nothing} = nothing,
    sparse_adj = nothing,
    jump_probability = nothing,
    graph_steps = 1,
) where {S,U}

    n_samples, n_features = size(X)
    if W === nothing
        W = fill(1.0, n_samples)
    end

    check_input(X, Y, W, max_features, max_depth, min_samples_leaf, min_samples_split, min_purity_increase, adj)

    root, indX =
        _fit(X, Y, W, max_features, max_depth, min_samples_leaf, min_samples_split, min_purity_increase, feature_sampling, rng, adj, sparse_adj, jump_probability, graph_steps)

    return Tree{S}(root, indX)

end
end
