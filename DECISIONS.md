# Decisions

- 2026-10-10 macOS 메뉴바 앱은 AppKit/WKWebView와 swiftc 직접 빌드, LSUIElement·최소 macOS 12로 구성 — Xcode 프로젝트·외부 의존성 없이 기존 Python 백엔드와 대시보드를 변경하지 않고 감쌈.
- 2026-10-10 기본 8765 기존 API 응답은 재사용하고 직접 실행한 Process만 종료, 로그인 자동 실행은 macOS 13 이상 SMAppService.mainApp 사용 — 기존 서버 소유권과 사용자 자동 실행 선택을 보존.
- 2026-10-10 arm64/x86_64 동시 빌드 실패 시 현재 아키텍처로 폴백하고 ad-hoc 서명·DMG 생성 — 이 Mac의 Command Line Tools SDK에는 x86_64 Swift 호환 정적 라이브러리가 없어 arm64 패키지로 검증.

- 2026-10-10 macOS 기본 데이터 경로를 ~/Library/Application Support/TokenTracker로 지정하고 TOKENTRACKER_HOME을 유지 — macOS 관례와 사용자 지정 경로를 함께 지원.
- 2026-10-10 Claude 인증은 macOS 키체인 Claude Code-credentials 우선, 인증 JSON 파일 폴백 — Claude Code의 실제 저장 방식에 맞추되 읽기 전용·비밀 출력 금지 유지.
- 2026-10-10 tkinter 부재/Tk 초기화 오류는 대시보드로 폴백, Aqua 창 속성·설치 글꼴·투명도 보정 — 별도 의존성 설치 없이 서버 사용 보장.
- 2026-10-10 macOS 브라우저·폴더는 open 명령, 실행·진단은 zsh 스크립트 — 공백 경로와 Mac 기본 앱 연결을 안전하게 처리.
- 2026-10-10 자동 시작은 사용자 실행형 LaunchAgent 설치/해제 스크립트로 제공, 이번 작업에서는 등록하지 않음 — 시스템 설정 변경은 사용자 선택에 맡기고 Python 절대 경로로 launchd PATH 차이 해결.
- 2026-10-10 Gemini 도구 필터와 기본 위젯 표시를 추가하고 한도 대신 오늘 토큰 수 표시 — 한도 API 없는 도구도 로컬 사용량 확인 가능.
- 2026-10-10 진단/API에 세 도구 전체 건수·토큰을 포함 — 로그 부재의 0건과 수집 성공을 명확하게 구별.
- 2026-10-10 쌀먹 비율은 정확한 롤링 30×24시간 비용/월 구독료로 계산하고 CLI/API/상단 표 카드에 공유 — 달력월·대시보드 필터·가입기간 보정으로 수치를 왜곡하지 않음.
- 2026-10-10 subscriptions 기본값과 사용자 설정은 Claude 20/Codex 20/Gemini 5 USD, 0·누락은 미설정 처리 — 사용자 확정 구독료를 반영하되 본인 요금제 수정 가능; 불완전 합계 배율은 숨김.
- 2026-10-10 LaunchAgent는 --dashboard --no-browser 및 ~/Library/Logs/TokenTracker 로그 경로 사용 — 위젯/브라우저 없이 단순 백그라운드 서버; 실제 launchctl 실행 없이 plist lint만 검증.
- 2026-10-10 Gemini 수집은 antigravity*/conversations/*.db(SQLite gen_metadata 프로토버프)를 직접 파싱 — Gemini CLI chats 폴더가 없고 transcript에는 토큰 수가 없어 사용량이 0으로 나왔음; 필드 4=input/5=cache_read 등은 역공학 추정.
- 2026-10-10 새 저장소 token-tracker-mac으로 분리, Swift 메뉴바 앱(.app/.dmg)으로 패키징, 원 저작자 MIT 표기 유지 — 파생작이므로 크레딧 보존; 백엔드는 기존 8765 재사용·없으면 번들 app.py 실행.
- 2026-10-10 캐시 적중률은 캐시읽기/(입력+캐시읽기+캐시쓰기)로 프로젝트·세션별 표시 — 작업별로 캐시가 안 먹히는 곳 식별.
