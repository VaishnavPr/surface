import httpx
from pathlib import Path


def _load_env() -> dict:
    env_file = Path.home() / ".config" / "gc-jira.env"
    env = {}
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip().strip('"')
    return env


def _client() -> tuple[httpx.Client, str]:
    env = _load_env()
    base_url = env["JIRA_URL"].rstrip("/")
    import base64
    token = base64.b64encode(f"{env['JIRA_EMAIL']}:{env['JIRA_TOKEN']}".encode()).decode()
    headers = {
        "Authorization": f"Basic {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    return httpx.Client(headers=headers, timeout=30), base_url


def search(jql: str, max_results: int = 100) -> list[dict]:
    client, base = _client()
    tickets = []
    start = 0
    with client:
        while True:
            r = client.post(f"{base}/rest/api/3/search/jql", json={
                "jql": jql,
                "startAt": start,
                "maxResults": max_results,
                "fields": ["summary", "status", "assignee", "issuetype", "priority"],
            })
            r.raise_for_status()
            data = r.json()
            issues = data.get("issues", [])
            for issue in issues:
                f = issue["fields"]
                tickets.append({
                    "key":      issue["key"],
                    "summary":  f.get("summary", ""),
                    "status":   f["status"]["name"] if f.get("status") else "",
                    "assignee": f["assignee"]["displayName"] if f.get("assignee") else None,
                    "type":     f["issuetype"]["name"] if f.get("issuetype") else "",
                    "priority": f["priority"]["name"] if f.get("priority") else "",
                })
            total = data.get("total", 0)
            start += len(issues)
            if start >= total or not issues:
                break
    return tickets


def get_issue(key: str) -> dict:
    client, base = _client()
    with client:
        r = client.get(f"{base}/rest/api/3/issue/{key}", params={
            "fields": "summary,status,assignee,issuetype,priority,description,comment,labels,fixVersions"
        })
        r.raise_for_status()
    issue = r.json()
    f = issue["fields"]

    def text_from_doc(doc) -> str:
        if not doc:
            return ""
        out = []
        for block in doc.get("content", []):
            for inline in block.get("content", []):
                if inline.get("type") == "text":
                    out.append(inline.get("text", ""))
        return " ".join(out).strip()

    comments = []
    for c in (f.get("comment") or {}).get("comments", [])[-5:]:
        author = c["author"]["displayName"] if c.get("author") else "?"
        body = text_from_doc(c.get("body"))
        comments.append({"author": author, "body": body})

    return {
        "key":         issue["key"],
        "summary":     f.get("summary", ""),
        "status":      f["status"]["name"] if f.get("status") else "",
        "assignee":    f["assignee"]["displayName"] if f.get("assignee") else None,
        "type":        f["issuetype"]["name"] if f.get("issuetype") else "",
        "priority":    f["priority"]["name"] if f.get("priority") else "",
        "description": text_from_doc(f.get("description")),
        "labels":      f.get("labels", []),
        "comments":    comments,
    }
