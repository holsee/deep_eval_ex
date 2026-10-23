locals_without_parens = [deftraced: 2, deftraced: 3, defptraced: 2, defptraced: 3]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
