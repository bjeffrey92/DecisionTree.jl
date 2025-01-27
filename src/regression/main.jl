include("tree.jl")

function _convert(node::treeregressor.NodeMeta{S}, labels::Array{T}) where {S, T <: Float64}
    if node.is_leaf
        return Leaf{T}(node.label, labels[node.region])
    else
        left = _convert(node.l, labels)
        right = _convert(node.r, labels)
        return Node{S, T}(node.feature, node.threshold, left, right)
    end
end

function build_stump(labels::AbstractVector{T}, features::AbstractMatrix{S}; rng = Random.GLOBAL_RNG) where {S, T <: Float64}
    return build_tree(labels, features, 0, 1)
end

function parse_sparse_adj_matrix_indices(indices)
    adj_dict = Dict()
    for i in unique(indices[1,:])
        adj_dict[i] = indices[2,indices[1,:] .== i]
    end
    return adj_dict
end


function build_tree(
        labels             :: AbstractVector{T},
        features           :: AbstractMatrix{S},
        n_subfeatures       = 0,
        max_depth           = -1,
        min_samples_leaf    = 5,
        min_samples_split   = 2,
        min_purity_increase = 0.0,
        feature_sampling    = 1.0;
        rng                 = Random.GLOBAL_RNG,
        adj                 = nothing,
        sparse_adj          = nothing,
        jump_probability    = nothing,
        graph_steps         = 1,
        ) where {S, T <: Float64}

    if max_depth == -1
        max_depth = typemax(Int)
    end
    if n_subfeatures == 0
        n_subfeatures = size(features, 2)
    end

    rng = mk_rng(rng)::Random.AbstractRNG
    t = treeregressor.fit(
        X                   = features,
        Y                   = labels,
        W                   = nothing,
        max_features        = Int(n_subfeatures),
        max_depth           = Int(max_depth),
        min_samples_leaf    = Int(min_samples_leaf),
        min_samples_split   = Int(min_samples_split),
        min_purity_increase = Float64(min_purity_increase),
        feature_sampling    = feature_sampling,
        rng                 = rng,
        adj                 = adj,
        sparse_adj          = sparse_adj,
        jump_probability    = jump_probability,
        graph_steps         = graph_steps)

    return _convert(t.root, labels[t.labels])
end

function parse_adj_dict(adj_dict)
    return Dict(convert(Int, i) => adj_dict[i] for i in keys(adj_dict))
end

function build_forest(
        labels              :: AbstractVector{T},
        features            :: AbstractMatrix{S},
        n_subfeatures       = -1,
        n_trees             = 10,
        partial_sampling    = 0.7,
        feature_sampling    = 0.7,
        max_depth           = -1,
        min_samples_leaf    = 5,
        min_samples_split   = 2,
        min_purity_increase = 0.0,
        jump_probability    = nothing;
        rng                 = Random.GLOBAL_RNG,
        adj                 = nothing,
        sparse_adj          = nothing,
        graph_steps         = 1) where {S, T <: Float64}

    if n_trees < 1
        throw("the number of trees must be >= 1")
    end
    if !(0.0 < partial_sampling <= 1.0)
        throw("partial_sampling must be in the range (0,1]")
    end

    if n_subfeatures == -1
        n_features = size(features, 2)
        n_subfeatures = round(Int, sqrt(n_features))
    end

    t_samples = length(labels)
    n_samples = floor(Int, partial_sampling * t_samples)

    forest = Vector{LeafOrNode{S, T}}(undef, n_trees)

    if !isnothing(sparse_adj) & isnothing(adj)
        adj_dict = parse_adj_dict(sparse_adj)
    else
        adj_dict = nothing
    end

    if rng isa Random.AbstractRNG
        Threads.@threads for i in 1:n_trees
            inds = rand(rng, 1:t_samples, n_samples)
            forest[i] = build_tree(
                labels[inds],
                features[inds,:],
                n_subfeatures,
                max_depth,
                min_samples_leaf,
                min_samples_split,
                min_purity_increase,
                feature_sampling,
                rng=rng,
                adj=adj,
                sparse_adj=adj_dict,
                jump_probability=jump_probability,
                graph_steps=graph_steps)
        end
    elseif rng isa Integer # each thread gets its own seeded rng
        Threads.@threads for i in 1:n_trees
            Random.seed!(rng + i)
            inds = rand(1:t_samples, n_samples)
            forest[i] = build_tree(
                labels[inds],
                features[inds,:],
                n_subfeatures,
                max_depth,
                min_samples_leaf,
                min_samples_split,
                min_purity_increase,
                feature_sampling,
                adj=adj,
                sparse_adj=adj_dict,
                jump_probability=jump_probability,
                graph_steps=graph_steps)
        end
    else
        throw("rng must of be type Integer or Random.AbstractRNG")
    end

    return Ensemble{S, T}(forest)
end
