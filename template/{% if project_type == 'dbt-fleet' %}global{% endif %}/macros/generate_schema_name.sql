{#-
  Dataset naming of the global project: one namespace per data product.

    root project models    <PREFIX>_<schema>
    a product's models     <PREFIX>_<PACKAGE>__<schema>

  PREFIX is DATASET_PREFIX when set (profiles/dbt.env), else the hub's
  dataset — the personal prefix the write guard demands either way. The
  per-product namespace keeps two products that use the same dataset and
  table names in production from overwriting each other in the sandbox.

  ⚠ dbt v2 applies this macro to the packages that do NOT define their own
  generate_schema_name. A product that ships one keeps it for its own nodes
  (observed with dbt 2.0.6): to land under the personal prefix, that macro
  must read DATASET_PREFIX itself — `just destinations global` shows what
  does not.

  PROJECT-OWNED: copier update never overwrites it.
-#}
{% macro generate_schema_name(custom_schema_name, node) -%}
  {%- set prefix = env_var('DATASET_PREFIX', '') or target.schema -%}
  {%- set custom = (custom_schema_name | trim) if custom_schema_name is not none else '' -%}
  {%- if node.package_name == project_name -%}
    {%- if custom -%}{{ (prefix ~ '_' ~ custom) | upper }}{%- else -%}{{ target.schema }}{%- endif -%}
  {%- else -%}
    {{ (prefix ~ '_' ~ node.package_name ~ ('__' ~ custom if custom else '')) | upper }}
  {%- endif -%}
{%- endmacro %}
