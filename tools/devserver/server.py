#!/usr/bin/env python3
"""本机测试执行服务：让 xcodebuild 脱离 WorkBuddy 沙盒跑起来。

关键前提：这个服务必须由 launchd 启动（打包成 .app，用 `open -n` 拉起）。
从沙盒里的 bash 直接 `python3 server.py &` 起不到作用——子进程照样继承沙盒。
判断办法看 GET /probe 里的 sandboxed 字段。

接口一览：
  GET  /health              存活检查，返回 pid / sandboxed
  GET  /probe               沙盒自查（env、log show、ps 各跑一次）
  POST /run?script=x.sh     异步执行项目根目录下的 sh 脚本（白名单）
  GET  /jobs                列出所有任务
  GET  /job?id=xxx&tail=80  查单个任务状态 + 日志尾部
  GET  /log?id=xxx&offset=N 增量读日志（offset 是字节偏移）
  POST /kill?id=xxx         杀掉任务（整组进程）
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# 项目根目录：服务由 launchd 启动时工作目录是 /，所以硬编码
PROJECT_DIR = "/Users/pan/Project/iOSDemo/MarkdownEditorHy4"
STATE_DIR = os.path.join(PROJECT_DIR, "build", "devserver")
SERVICE_LOG = "/tmp/mdhy4-testrunner.log"
HOST = "127.0.0.1"
PORT = 8765

# 只允许跑白名单目录下真实存在的 .sh，避免变成一个万能后门
ALLOWED_SCRIPT_PATTERN = ".sh"
# 允许放脚本的目录，相对项目根；空串代表根目录本身
ALLOWED_SCRIPT_DIRS = ("", "tools")
MAX_CONCURRENT_JOBS = 1

_jobs: dict[str, dict] = {}
_jobs_lock = threading.Lock()


def log(message: str) -> None:
    """服务自身日志，追加到固定文件（launchd 会把 stdout 丢掉，只能自己写）。"""
    line = f"[{time.strftime('%H:%M:%S')}] {message}\n"
    try:
        with open(SERVICE_LOG, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass


def is_sandboxed() -> bool:
    """看环境变量判断有没有被 WorkBuddy 的沙盒包住。"""
    keys = ("TOYBOX_SANDBOX_SOCK", "CODEBUDDY_SANDBOX_BROKER_IPC_ADDRESS", "CODEBUDDY_TOYBOX_SANDBOX_PROFILE")
    return any(os.environ.get(k) for k in keys)


def resolve_script(script: str) -> str | None:
    """把请求里的脚本名解析成绝对路径，不合规一律返回 None。

    三条限制：后缀必须是 .sh、必须落在白名单目录、解析完不能跑到项目外面去。
    """
    if not script.endswith(ALLOWED_SCRIPT_PATTERN):
        return None
    if script.startswith("/") or ".." in script.split("/"):
        return None
    if os.path.dirname(script) not in ALLOWED_SCRIPT_DIRS:
        return None
    real = os.path.realpath(os.path.join(PROJECT_DIR, script))
    root = os.path.realpath(PROJECT_DIR)
    if not real.startswith(root + os.sep):
        return None
    return real if os.path.isfile(real) else None


def tail_file(path: str, lines: int = 80) -> str:
    """读文件最后 N 行，只从末尾读 64KB，避免大日志把内存吃满。"""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            block = min(size, 65536)
            f.seek(size - block)
            data = f.read().decode("utf-8", "replace")
        return "\n".join(data.splitlines()[-lines:])
    except OSError:
        return ""


def run_probe_command(argv: str, timeout: float = 8.0) -> dict:
    """跑一条诊断命令，返回输出与退出码。"""
    try:
        done = subprocess.run(
            ["/bin/bash", "-lc", argv],
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=PROJECT_DIR,
        )
        return {"cmd": argv, "code": done.returncode, "out": (done.stdout + done.stderr).strip()[:2000]}
    except subprocess.TimeoutExpired:
        return {"cmd": argv, "code": -1, "out": "timeout"}
    except OSError as exc:
        return {"cmd": argv, "code": -1, "out": f"OSError: {exc}"}


def save_job(job: dict) -> None:
    """把任务状态落盘，服务重启后还能查到历史。"""
    os.makedirs(STATE_DIR, exist_ok=True)
    snapshot = {k: v for k, v in job.items() if k != "proc"}
    path = os.path.join(STATE_DIR, f"{job['id']}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(snapshot, f, ensure_ascii=False, indent=2)


def load_previous_jobs() -> None:
    """启动时把上次的任务记录读回来；上次还在 running 的标记为 interrupted。"""
    if not os.path.isdir(STATE_DIR):
        return
    for name in os.listdir(STATE_DIR):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(STATE_DIR, name), encoding="utf-8") as f:
                job = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if job.get("state") == "running":
            job["state"] = "interrupted"
        _jobs[job["id"]] = job


def job_public_view(job: dict, tail: int = 0, offset: int = -1) -> dict:
    """给 HTTP 响应用的任务快照，不带 Popen 对象。"""
    view = {k: v for k, v in job.items() if k != "proc"}
    view["running"] = job.get("state") == "running"
    if tail > 0:
        view["tail"] = tail_file(job["log"], tail)
    if offset >= 0:
        try:
            with open(job["log"], "rb") as f:
                f.seek(min(offset, os.path.getsize(job["log"])))
                chunk = f.read(262144).decode("utf-8", "replace")
            view["chunk"] = chunk
            view["nextOffset"] = min(offset, os.path.getsize(job["log"])) + len(chunk.encode("utf-8"))
        except OSError:
            view["chunk"] = ""
            view["nextOffset"] = offset
    return view


def start_job(script: str, timeout: int) -> dict:
    """启动一个 sh 脚本，输出重定向到独立日志文件。"""
    script_path = os.path.join(PROJECT_DIR, script)
    job_id = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]
    os.makedirs(STATE_DIR, exist_ok=True)
    log_path = os.path.join(STATE_DIR, f"{job_id}.log")

    env = dict(os.environ)
    # launchd 给的 PATH 很短，补齐常用的几个目录，xcodebuild 及其子工具才找得到
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
    env.setdefault("HOME", os.path.expanduser("~"))
    env["LC_ALL"] = "en_US.UTF-8"
    env["LANG"] = "en_US.UTF-8"

    log_file = open(log_path, "wb")
    proc = subprocess.Popen(
        ["/bin/bash", script_path],
        cwd=PROJECT_DIR,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        env=env,
        start_new_session=True,  # 独立进程组，方便整组杀掉
    )

    job = {
        "id": job_id,
        "script": script,
        "state": "running",
        "pid": proc.pid,
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "finishedAt": None,
        "exitCode": None,
        "timeoutSeconds": timeout,
        "log": log_path,
        "proc": proc,
    }
    with _jobs_lock:
        _jobs[job_id] = job
    save_job(job)
    log(f"job {job_id} started: {script} (pid {proc.pid})")
    _watch_job(job, log_file)
    return job


def _watch_job(job: dict, log_file) -> None:
    """后台线程等进程结束，写回退出码；超时就整组杀掉。"""
    deadline = time.time() + job["timeoutSeconds"]

    def wait() -> None:
        proc: subprocess.Popen = job["proc"]
        while proc.poll() is None:
            if time.time() > deadline:
                log(f"job {job['id']} timeout, killing process group")
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except OSError:
                    pass
                job["state"] = "timeout"
                break
            time.sleep(1.0)
        code = proc.poll()
        with _jobs_lock:
            if job["state"] == "running":
                job["state"] = "finished"
            job["exitCode"] = code
            job["finishedAt"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        log_file.close()
        save_job(job)
        log(f"job {job['id']} {job['state']} exit={code}")

    threading.Thread(target=wait, daemon=True).start()


class Handler(BaseHTTPRequestHandler):
    server_version = "MDHy4TestRunner/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003 - 覆盖基类签名
        log("http " + fmt % args)

    def _send(self, payload: dict, code: int = 200) -> None:
        body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler 约定的方法名
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        route = parsed.path

        if route == "/health":
            self._send({"ok": True, "pid": os.getpid(), "sandboxed": is_sandboxed(), "projectDir": PROJECT_DIR})
            return

        if route == "/probe":
            # 这三条是当年判定「在不在沙盒里」的判据，原样跑一遍
            probes = [
                run_probe_command("env | grep -c -E 'TOYBOX_SANDBOX|CODEBUDDY_SANDBOX' || true"),
                run_probe_command("/usr/bin/log show --last 1m --style compact 2>&1 | head -3"),
                run_probe_command("ps -o pid,ppid,command -p $$ 2>&1"),
                run_probe_command("xcodebuild -version 2>&1"),
                run_probe_command("xcode-select -p 2>&1"),
                run_probe_command("whoami; id -un 2>&1"),
            ]
            self._send({"sandboxed": is_sandboxed(), "probes": probes})
            return

        if route == "/jobs":
            with _jobs_lock:
                items = [job_public_view(j) for j in _jobs.values()]
            items.sort(key=lambda j: j["startedAt"] or "", reverse=True)
            self._send({"jobs": items[:20]})
            return

        if route == "/job":
            job_id = (query.get("id") or [""])[0]
            tail = int((query.get("tail") or ["0"])[0])
            job = _jobs.get(job_id)
            if not job:
                self._send({"error": "no such job", "id": job_id}, 404)
                return
            self._send(job_public_view(job, tail=tail))
            return

        if route == "/log":
            job_id = (query.get("id") or [""])[0]
            offset = int((query.get("offset") or ["0"])[0])
            job = _jobs.get(job_id)
            if not job:
                self._send({"error": "no such job", "id": job_id}, 404)
                return
            self._send(job_public_view(job, offset=offset))
            return

        self._send({"error": "unknown route", "routes": ["/health", "/probe", "/run", "/jobs", "/job", "/log"]}, 404)

    def do_POST(self) -> None:  # noqa: N802 - 同上
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        route = parsed.path

        if route == "/run":
            script = (query.get("script") or [""])[0]
            timeout = int((query.get("timeout") or ["1800"])[0])
            if resolve_script(script) is None:
                self._send({"error": f"脚本不可用（须是项目根目录或 tools/ 下的 .sh）: {script}"}, 400)
                return
            with _jobs_lock:
                running = sum(1 for j in _jobs.values() if j.get("state") == "running")
            if running >= MAX_CONCURRENT_JOBS:
                self._send({"error": "已有任务在跑，先 /kill 或等它结束"}, 409)
                return
            job = start_job(script, timeout)
            self._send({"id": job["id"], "pid": job["pid"], "state": job["state"], "log": f"/log?id={job['id']}"})
            return

        if route == "/kill":
            job_id = (query.get("id") or [""])[0]
            job = _jobs.get(job_id)
            if not job:
                self._send({"error": "no such job", "id": job_id}, 404)
                return
            proc = job.get("proc")
            if proc and proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except OSError:
                    pass
                time.sleep(1.0)
                if proc.poll() is None:
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except OSError:
                        pass
            self._send({"id": job_id, "state": job.get("state"), "exitCode": job.get("exitCode")})
            return

        self._send({"error": "unknown route"}, 404)


def main() -> int:
    os.makedirs(STATE_DIR, exist_ok=True)
    log("=" * 60)
    log(f"service starting, pid={os.getpid()}, sandboxed={is_sandboxed()}")
    load_previous_jobs()
    try:
        server = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as exc:
        log(f"bind failed on {HOST}:{PORT}: {exc}")
        print(f"bind failed: {exc}", file=sys.stderr)
        return 1
    server.daemon_threads = True
    log(f"listening on http://{HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("interrupted")
    return 0


if __name__ == "__main__":
    sys.exit(main())
