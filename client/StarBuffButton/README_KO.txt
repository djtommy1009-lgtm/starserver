[스타서버 버프 버튼 DLL 시험본]

목적
- 게임 창 내부 우측 하단에 '버프' 버튼을 표시합니다.
- 클릭하면 현재 서버에 이미 존재하는 유저 명령어 '.버프'를 게임 입력 경로로 실행합니다.
- 서버 패킷 opcode나 Star.bin 내부 주소를 추측하여 패치하지 않습니다.

구성
- version.dll: x86 Windows Version API 프록시 + 인게임 창 오버레이 버튼
- StarBuffButton.ini: 버튼 위치·크기·진단 설정
- BUILD_RESULT.txt: 빌드 대상, SHA-256, 실행시험 상태
- dumpbin_headers.txt: x86 PE 헤더 검사 결과
- dumpbin_exports.txt: Version API export 검사 결과
- version_proxy.cpp / version.def: 전체 빌드 소스

버튼 표시 방식
- 별도 PNG/BMP 이미지를 사용하지 않습니다.
- DLL이 GDI로 어두운 배경, 금색 테두리, '버프' 글자를 직접 그립니다.
- 이것은 Star.bin의 원본 UI XML을 수정한 방식이 아니라 게임 창 내부에 그리는 시험용 인프로세스 버튼입니다.

적용 전 필수 확인
1. Star.bin이 있는 클라이언트 폴더 전체를 복사해 시험용 폴더를 만듭니다.
2. 시험용 폴더에 version.dll이 이미 있으면 덮어쓰지 마십시오.
3. 기존 version.dll이 있다면 해당 파일을 별도 보관하고 이 시험본 적용을 중단하십시오.
4. 한 계정, 한 클라이언트에서만 먼저 시험하십시오.

적용
1. version.dll과 StarBuffButton.ini를 Star.bin 옆에 복사합니다.
2. 접속기로 시험 클라이언트를 실행합니다.
3. StarBuffButton.log가 생성되는지 확인합니다.
4. 로그에서 'button installed successfully'를 확인합니다.
5. 게임 창 우측 하단의 '버프' 버튼을 한 번 클릭합니다.
6. 기존 '.버프' 직접 입력과 같은 결과가 나오는지 확인합니다.
7. 귀환, 텔레포트, 인벤토리 열기·닫기 후 다시 시험합니다.

복원
- 추가한 version.dll, StarBuffButton.ini, StarBuffButton.log를 삭제합니다.
- 기존 version.dll을 보관했다면 원래 파일로 복원합니다.
- 기존 StarMarketCore.dll, ddraw.dll, dinput.dll, StarGuard.dll은 변경하지 않습니다.

주의
- x86 MSVC 컴파일 및 PE/export 검사는 완료됐습니다.
- 실제 스타 클라이언트 실행 시험은 이 빌드 환경에서 수행하지 못했습니다.
- 전체 유저에게 배포하기 전에 시험용 클라이언트에서 반드시 확인하십시오.
- 클릭은 750ms 중복 방지됩니다.
- 버튼 위치는 INI의 OffsetX, OffsetY로 조정합니다.
- 버튼 클릭 시 채팅 입력창을 열어 '.버프'를 입력하고 전송합니다. 명령어는 일반 채팅으로 방송되지 않아야 하며, 현재 서버의 기존 유저 명령어 처리 결과와 일치해야 합니다.

진단
- StarBuffButton.log가 없으면 로컬 version.dll이 로드되지 않은 것입니다.
- 버튼이 없으면 로그의 SetWindowLongPtr 또는 game window 검색 실패를 확인합니다.
- 버튼은 보이나 명령이 실행되지 않으면 '.버프' 수동 입력이 현재 클라이언트에서 정상인지 먼저 확인합니다.
- 실행 직후 충돌하면 즉시 파일을 제거하고 LinError.log와 StarBuffButton.log를 보관합니다.
