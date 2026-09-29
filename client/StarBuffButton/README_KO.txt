[스타서버 버프 버튼 DLL]

목적
- 게임 창 내부 우측 하단에 '버프' 버튼을 표시합니다.
- 클릭 시 ASCII 서버 액션 star_buff를 게임 채팅 입력 경로로 전송합니다.
- 서버에는 StarOverlayActionService의 star_buff 처리 Java가 먼저 적용되어 있어야 합니다.

구성
- version.dll: x86 Version API 프록시 + 버프 버튼
- StarBuffButton.ini: 위치·크기·진단 설정

적용
1. Star.bin이 있는 클라이언트 폴더를 백업합니다.
2. 같은 폴더에 기존 version.dll이 존재하면 절대 덮어쓰지 말고 별도 보관합니다.
3. version.dll과 StarBuffButton.ini를 Star.bin 옆에 복사합니다.
4. 접속기로 게임을 실행합니다.
5. StarBuffButton.log에서 'button installed successfully'를 확인합니다.
6. 게임 창 우측 하단의 버프 버튼을 클릭합니다.

복원
- 추가한 version.dll과 StarBuffButton.ini를 삭제합니다.
- 기존 version.dll을 보관했다면 원래 파일로 복구합니다.

주의
- 기존 StarMarketCore.dll, ddraw.dll, dinput.dll, StarGuard.dll은 교체하지 않습니다.
- 이 DLL은 시스템 version.dll의 Version API를 그대로 전달합니다.
- 실제 클라이언트 실행 시험 전에는 운영 전체 배포를 하지 마십시오.
- 클릭 입력은 750ms 중복 방지됩니다.
- 버튼 위치는 INI의 OffsetX, OffsetY로 조정합니다.

진단
- 버튼이 보이지 않으면 StarBuffButton.log를 확인합니다.
- 로그 파일이 생기지 않으면 로컬 version.dll이 로드되지 않은 것입니다.
- 버튼은 보이지만 동작하지 않으면 서버 Java의 star_buff 처리와 게임 채팅 전송 경로를 확인합니다.
