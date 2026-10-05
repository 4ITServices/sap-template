# Shared models

The models that several data products share land here, as the
cross-product refactoring moves them out of the products' v2. A model here
is in the root project: it writes to `<PREFIX>_<schema>` (see
`macros/generate_schema_name.sql`), and the products reach it with
`ref('<project name>', '<model>')` once they are packages of this project.
