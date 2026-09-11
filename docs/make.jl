using CorePotts
using Documenter

makedocs(
    sitename = "CorePotts.jl",
    authors = "Praneeth Merugu",
    modules = [CorePotts],
    doctest = true,
    warnonly = false,
    pagesonly = true,
    checkdocs = :exports,
    remotes = nothing,
    format = Documenter.HTML(repolink = "https://github.com/PraneethMerugu/CorePotts.jl"),
    pages = ["Home" => "index.md", "API" => "api/corepotts.md"],
)
