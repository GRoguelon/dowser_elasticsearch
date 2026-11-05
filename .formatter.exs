# The migration DSL `dowser_client` defines (`create_index`, `add`, …),
# exported so that an application's `import_deps: [:dowser_elasticsearch]`
# keeps it without parentheses — `dowser_client` isn't one of its own deps.
locals_without_parens = [
  create_index: 2,
  create_index: 3,
  drop_index: 1,
  drop_index: 2,
  alter_index: 2,
  alter_index: 3,
  add: 2,
  add: 3,
  modify: 2,
  modify: 3,
  rename: 2,
  remove: 1,
  remove: 2,
  set: 2,
  set: 3,
  unset: 1,
  unset: 2,
  script: 1,
  script: 2
]

# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  export: [locals_without_parens: locals_without_parens]
]
