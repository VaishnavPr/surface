import httpx
from pathlib import Path


def _load_env() -> dict:
    env_file = Path.home() / ".config" / "gc-jenkins.env"
    env = {}
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("#"):
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip().strip('"')
    return env


def _client(instance: str = "prod") -> tuple[httpx.Client, str]:
    env = _load_env()
    url = env["JENKINS_TESTING_URL"] if instance == "test" else env["JENKINS_URL"]
    auth = (env["JENKINS_USER"], env["JENKINS_TOKEN"])
    client = httpx.Client(auth=auth, verify=False, timeout=30)
    return client, url


def fetch_jobs(instance: str = "prod") -> list[dict]:
    client, url = _client(instance)
    with client:
        r = client.get(f"{url}/api/json?tree=jobs[name,color,jobs[name,color,jobs[name,color]]]")
        r.raise_for_status()

    def walk(jobs, prefix=""):
        results = []
        for j in jobs:
            path = f"{prefix}{j['name']}" if prefix else j["name"]
            sub = j.get("jobs")
            if sub:
                results.extend(walk(sub, f"{path}/"))
            else:
                results.append({"path": path, "color": j.get("color", "")})
        return results

    return walk(r.json().get("jobs", []))


def fetch_params(job_path: str, instance: str = "prod") -> list[dict]:
    import re
    url_path = "job/" + job_path.replace("/", "/job/")
    client, base = _client(instance)
    with client:
        r = client.get(
            f"{base}/{url_path}/api/json",
            params={"tree": "property[parameterDefinitions[name,type,defaultParameterValue[value],description,choices]]"},
        )
        r.raise_for_status()

    params = []
    for prop in r.json().get("property", []):
        for p in prop.get("parameterDefinitions", []):
            default_obj = p.get("defaultParameterValue") or {}
            default = str(default_obj.get("value") or "")
            desc = re.sub(r"<[^>]+>", "", p.get("description", "") or "").strip().replace("\n", " ")
            params.append({
                "name":    p.get("name", ""),
                "type":    p.get("type", ""),
                "default": default,
                "desc":    desc,
                "choices": p.get("choices", []) or [],
            })
    return params


def trigger(job_path: str, params: dict[str, str], instance: str = "prod") -> int:
    url_path = "job/" + job_path.replace("/", "/job/")
    client, base = _client(instance)
    endpoint = "buildWithParameters" if params else "build"
    with client:
        r = client.post(f"{base}/{url_path}/{endpoint}", data=params)
    return r.status_code


def last_build(job_path: str, instance: str = "prod") -> dict:
    url_path = "job/" + job_path.replace("/", "/job/")
    client, base = _client(instance)
    with client:
        r = client.get(
            f"{base}/{url_path}/lastBuild/api/json",
            params={"tree": "number,result,timestamp,duration,building,url"},
        )
        r.raise_for_status()
    return r.json()
