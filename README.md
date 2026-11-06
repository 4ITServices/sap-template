# sap-template
sap-template

Modèle copier des projets 4IT (SAP, dbt, MCP). Documentation complète :
[`template/.devcontainer/README.md.jinja`](template/.devcontainer/README.md.jinja)
(rendu en `.devcontainer/README.md` dans chaque projet), dont :

- « Post-`copier update` checklist » — après chaque mise à jour ;
- « Passer un projet existant à keyvault » — la liste à suivre pour chaque
  projet (`.env.refs`, `claude_profile`, lecteurs de `.env`, origin en https,
  migration de l'historique, `chmod -R go-w .`) ;
- « Claude profiles » — un compte Claude, un historique et des réglages par
  container.

