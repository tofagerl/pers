---
name: pers-create-api-request
description: Use when the user wants to add, create, save, or update an HTTP request in the Pers API tester for the repo they are working in, e.g. "add this endpoint to pers", "make a pers request for /search", "save this curl in the API tester".
---

# Pers API tester requests

Pers (the macOS app) keeps the API tester's saved requests in `~/Library/Application Support/Pers/requests.json`, a JSON array. The app watches the folder and reloads when the file is replaced, then opens the newly added request, so a request written here shows up in a running app without a restart.

Requests are grouped into folders by `repo`. A folder exists for every distinct `repo` value, so setting `repo` correctly is what files the request in the right app folder.

## Request fields

| Field | Meaning |
|---|---|
| `id` | Uppercase UUID, e.g. from `uuidgen`. |
| `repo` | Absolute path of the repo's **main checkout**, which all its worktrees share. This is the folder. |
| `name` | Display name in the folder's list. |
| `method` | One of `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`. |
| `url` | Full URL including scheme and query string, percent-encoded. |
| `headers` | `Name: value` lines in one string, `\n` separated. Lines starting with `#` are ignored. |
| `body` | Request body as a string, e.g. pretty-printed JSON. Ignored for `GET` and `HEAD`. |

Always write all seven fields, using `""` for empty ones, so entries match the ones the app saves.

## Steps

1. Find the repo path: `git worktree list --porcelain | head -1`, taking the first `worktree` entry. Do not use `--show-toplevel`, which returns the worktree you happen to be in.
2. Work out the request from the repo's code rather than guessing: controller/route definitions for path, method, parameters and payload shape; `application*.yml`/`.properties`, `.env`, Dockerfiles or k8s manifests for the port and service hostnames; tests or README for realistic example values. If the user gave a curl command or URL, translate that instead. If what they want is unclear, ask.
3. Read `requests.json` and look at the existing entries for this `repo` to match their host, brand and naming style.
4. Name it in the style the user already uses: `<brand> <env> <path> <distinguishing params>`, lowercase except for literal values, without the method, e.g. `finn prod /suggest FRONTPAGE oslo` or `local /search BAP_COMMON iphone`. Leave out parts that don't apply (a repo with one brand needs no brand). The name must tell it apart from the other requests in the folder.
5. Headers:
   - Add `Content-Type: application/json` when sending a JSON body.
   - Never write a secret value. The app runs header values containing `$` through the shell in the repo's directory, so use a lookup such as `Authorization: Bearer $(secret get …)` or `$(security find-generic-password -s name -w)`.
6. If a request with the same `repo` and `name` exists, update it in place and keep its `id`. Otherwise append it at the end, which also makes the app select it. Write with `jq`, building the object with `jq -n --arg …`, then write to a temp file in the same folder and `mv` it over `requests.json`. Replacing the file is what triggers the app's reload; preserve every other entry.
7. Verify with `jq` that the file is still a valid array containing the new request, then tell the user the folder (the repo's directory name) and the request name.

## Example

```json
{
  "id": "3F6B2C1E-7A4D-4E8B-9C35-1D2A8E5F0B47",
  "repo": "/Users/me/dev/search-newfrontier",
  "name": "finn prod /suggest FRONTPAGE oslo",
  "method": "GET",
  "url": "http://search-newfrontier.horizontal.svc.finn.no/search/newfrontier/suggest?term=oslo&where=FRONTPAGE",
  "headers": "",
  "body": ""
}
```

Appending with `jq`:

```bash
f="$HOME/Library/Application Support/Pers/requests.json"
new=$(jq -n --arg id "$(uuidgen)" --arg repo "$repo" --arg name "$name" --arg method POST \
  --arg url "$url" --arg headers "Content-Type: application/json" --arg body "$body" \
  '{id: $id, repo: $repo, name: $name, method: $method, url: $url, headers: $headers, body: $body}')
jq --argjson new "$new" '. + [$new]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
```
