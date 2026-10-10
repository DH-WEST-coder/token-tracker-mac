"""토큰 트래커 — Claude Code / Codex / Gemini usage + remaining limits.

    python app.py              위젯 + 대시보드 (기본)
    python app.py --dashboard  위젯 없이 대시보드만 (브라우저로 열림)
    python app.py --scan       로그를 한 번 읽고 결과만 출력
    python app.py --doctor     어떤 로그를 찾았는지, 한도 조회가 되는지 점검
    python app.py --export DIR 대시보드 아티팩트용 JSON 파일 내보내기
"""
import argparse
import json
import signal
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from tracker import paths, stats  # noqa: E402
from tracker.collectors import scan_all  # noqa: E402
from tracker.db import DB  # noqa: E402
from tracker.engine import Engine  # noqa: E402
from tracker.limits import all_limits  # noqa: E402
from tracker.server import serve  # noqa: E402


def already_running(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/limits", timeout=1.5) as r:
            return r.status == 200
    except Exception:
        return False


def fmt_ts(ts):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts)) if ts else "-"


def cmd_scan():
    db = DB()
    t = time.time()
    rep = scan_all(db)
    print(json.dumps(rep, ensure_ascii=False, indent=2))
    print(f"\n{time.time() - t:.1f}초 · DB: {db.path}")
    tod = stats.today(db)
    print("오늘:", {k: (v["tokens"], round(v["cost"], 2)) for k, v in tod.items()})


def cmd_doctor():
    db = DB()
    print("데이터 폴더 :", paths.data_dir())
    print("Claude 로그 :", [str(p) for p in paths.claude_project_dirs()] or "못 찾음")
    _, credential_source = paths.claude_oauth_credentials()
    print("Claude 인증 :", credential_source)
    try:
        import tkinter
        print("위젯 지원   : tkinter", tkinter.TkVersion, "(GUI 창은 진단에서 열지 않음)")
    except ImportError:
        print("위젯 지원   : tkinter 없음 — 대시보드만 사용 가능")
    print("Codex 로그  :", [str(p) for p in paths.codex_session_dirs()] or "못 찾음")
    print("Gemini 폴더 :", paths.gemini_root(), "(있음)" if paths.gemini_root().exists() else "(없음)")
    gemini_tmp = paths.gemini_root() / "tmp"
    gemini_chats = list(gemini_tmp.glob("*/chats/*.json"))
    print("Gemini CLI  :", str(gemini_tmp / "*" / "chats" / "*.json"),
          f"({len(gemini_chats)}개 파일)")
    from tracker import collectors
    print("Antigravity :", str(paths.gemini_root() / "antigravity*" / "conversations" / "*.db"),
          f"({len(collectors._antigravity_dbs())}개 파일)")
    print("\n로그 읽는 중…")
    print(json.dumps(scan_all(db), ensure_ascii=False, indent=2))
    print("\n수집된 기록 (전체 기간):")
    for s, c in stats.source_totals(db).items():
        print(f"  {s:7s} {c['calls']:>8,}건  {c['tokens']:>14,}토큰  "
              f"{fmt_ts(c['first'])} ~ {fmt_ts(c['last'])}")
    print("\n한도:")
    for s, l in all_limits(db, force=True).items():
        wins = ", ".join(f"{w['label']} {w['used_percent']:.0f}% 사용" for w in l.get("windows", []))
        print(f"  {s:7s} [{l.get('status')}] {wins or '-'} {l.get('message', '')}")


def cmd_ratio():
    db = DB()
    try:
        scan_all(db)
        data = stats.subscription_ratio(db)
        print("쌀먹 비율 · 롤링 최근 30일 · API 환산 비용 추정치 (실제 절약/청구액 아님)")
        print(f"{'도구':<12} {'30일 API환산$':>15} {'구독$/월':>12} {'배율x':>14} {'절약액$':>14}")
        for source, row in [*data["by_source"].items(), ("합계", data["total"])]:
            ratio = f"{row['ratio']:.2f}x" if row["ratio"] is not None else "구독료 미설정"
            savings = f"{row['savings_usd']:,.2f}" if row["savings_usd"] is not None else "-"
            print(f"{source:<12} {row['api_cost_usd']:>15,.2f} "
                  f"{row['subscription_usd']:>12,.2f} {ratio:>14} {savings:>14}")
    finally:
        db.conn.close()


def main():
    ap = argparse.ArgumentParser(description="토큰 트래커")
    ap.add_argument("--dashboard", action="store_true", help="위젯 없이 대시보드만")
    ap.add_argument("--no-browser", action="store_true", help="대시보드를 자동으로 열지 않음")
    ap.add_argument("--scan", action="store_true")
    ap.add_argument("--doctor", action="store_true")
    ap.add_argument("--ratio", action="store_true", help="롤링 30일 API환산/구독료 배율 표")
    ap.add_argument("--export", metavar="FOLDER", help="대시보드용 JSON 내보내기")
    ap.add_argument("--port", type=int)
    a = ap.parse_args()

    if a.scan:
        return cmd_scan()
    if a.doctor:
        return cmd_doctor()
    if a.ratio:
        return cmd_ratio()
    if a.export:
        from tracker.export import export
        db = DB()
        scan_all(db)
        print(export(db, a.export), "->", a.export)
        return

    port = a.port or paths.load_config().get("port", 8765)
    if already_running(port):  # second launch: just open the dashboard
        if not a.no_browser:
            paths.open_location(f"http://127.0.0.1:{port}/")
        return

    # launchd sends SIGTERM on bootout; use the same cleanup as Ctrl+C.
    def terminate(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    engine = Engine()
    httpd = widget = None
    try:
        engine.refresh()
        engine.start()
        httpd, url = serve(engine, port=port, background=True)
        if not a.dashboard:
            try:
                from tracker.widget import Widget
            except ImportError:
                print("tkinter가 없어 대시보드 모드로 실행합니다", flush=True)
            else:
                import tkinter as tk
                try:
                    widget = Widget(engine, url)
                except tk.TclError:
                    print("Tk GUI를 초기화할 수 없어 대시보드 모드로 실행합니다", flush=True)
        print(f"대시보드: {url}   (끄려면 Ctrl+C)", flush=True)
        if widget is not None:
            widget.run()
        else:
            if not a.no_browser:
                paths.open_location(url)
            while True:
                time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        if widget is not None:
            try:
                widget.root.destroy()
            except Exception:
                pass
        engine.stop()
        if httpd is not None:
            httpd.shutdown()
            httpd.server_close()


if __name__ == "__main__":
    main()
