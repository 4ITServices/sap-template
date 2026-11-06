# secrets — les secrets de dev sans .env en clair

Les secrets ne vivent plus dans les `.env`. Ils sont dans des coffres Azure Key Vault, et chacun
les lit **avec sa propre identité** Entra (`az login`). Chaque lecture est journalisée à son nom.

| Coffre | Contenu | Qui lit |
|---|---|---|
| `kv-4it-dev-partage` | robots et comptes techniques de dev, clés LLM, principaux de service | groupe « 4IT développeurs » |
| `kv-4it-dev-perso-<alias>` | tes identifiants nominatifs (compte SAP, PAT abapGit…) | toi seul (« 4IT perso &lt;alias&gt; ») |

Le code de ces coffres, groupes et rôles : `tofu/stacks/secrets` (appliqué en local, pas par la CI).

## Démarrer (une fois)

```bash
az login                      # ton compte @4it-services.com, tenant 4IT Services
gh auth login                 # ton identité GitHub (remplace le PAT partagé)
just secrets-install          # depuis ce dépôt : lien ~/.local/bin/secrets
secrets qui                   # vérifie ton compte et ton coffre perso
```

Ton compte doit figurer dans [`personnes.conf`](personnes.conf) ; sinon, demande à JB.

Remplis ton coffre perso (la valeur est saisie masquée, jamais affichée ni écrite sur disque) :

```bash
secrets set kv://perso/sap-user
secrets set kv://perso/sap-password
```

## Tous les jours

Dans un projet, le fichier `.env.refs` remplace le `.env` : il ne contient **aucune valeur secrète**,
seulement des références, et peut donc être versionné.

```bash
secrets check                 # chaque référence se résout-elle ? (noms seulement)
secrets run -- claude         # lance Claude Code avec les variables résolues en mémoire
secrets run -- just dev       # ou n'importe quelle commande
secrets run -f .env.ecc.refs -- just dev   # un autre fichier
```

Format de `.env.refs` :

```bash
AZURE_AI_API_KEY=kv://kv-4it-dev-partage/azure-ai-api-key   # secret partagé
SAP_USER=kv://perso/sap-user                                 # ton coffre perso
SAP_PASSWORD=kv://perso/sap-password
GITHUB_PERSONAL_ACCESS_TOKEN=gh://token                      # = gh auth token
SAP_URL=https://sap.exemple:44300                            # config non secrète : en clair
```

Les variables de `.env.refs` l'emportent sur celles déjà présentes dans l'environnement ; un `.env`
restant dans le projet est ignoré par pydantic-settings et python-dotenv quand la variable existe déjà.

## Serveurs MCP (`.mcp.json`)

Lancé par `secrets run -- claude`, Claude Code hérite des variables : `"Authorization": "Bearer ${SAP_ADT_MCP_TOKEN}"`
suffit. Pour lire le secret au moment de la connexion, sans dépendre du lancement, utiliser `headersHelper` :

```json
"sap-adt": {
  "type": "http",
  "url": "http://127.0.0.1:8000/mcp",
  "headersHelper": "secrets mcp-headers 'Authorization=Bearer kv://kv-4it-dev-partage/sap-adt-mcp-token'"
}
```

`secrets mcp-headers` écrit les en-têtes (donc le secret) sur sa sortie, à destination de Claude Code :
ne pas le lancer à la main.

## Règles

- Jamais de secret dans un fichier versionné, dans le chat, ni sur une ligne de commande.
- Le lanceur n'écrit aucune valeur sur disque et ne passe ni jeton ni valeur en argument (`ps`).
- Ajouter un secret partagé : demander à un gestionnaire (« 4IT gestionnaires coffre »).

## Qui a lu quoi (Log Analytics `log-4it-secrets-dev`)

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT" and OperationName in ("SecretGet", "SecretSet")
| extend qui = identity_claim_http_schemas_xmlsoap_org_ws_2005_05_identity_claims_upn_s
| project TimeGenerated, Resource, OperationName, secret = tostring(split(id_s, "/")[4]), qui, CallerIPAddress, httpStatusCode_d
| order by TimeGenerated desc
```

Les premiers journaux d’un espace neuf peuvent mettre jusqu’à ~1 h 30 à arriver.
