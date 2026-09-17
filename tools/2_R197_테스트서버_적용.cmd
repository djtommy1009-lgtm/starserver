@echo off
setlocal EnableExtensions
chcp 65001 >nul
title R197 테스트 서버 후보 JAR 적용

echo 테스트 서버를 정상 종료한 상태에서만 진행합니다.
echo 운영 서버 JAR은 변경하지 않습니다.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0R197_테스트서버_후보JAR_적용.ps1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo [실패] 테스트 JAR 적용이 완료되지 않았습니다.
) else (
    echo [완료] 기존 테스트 서버 시작 파일로 테스트 서버를 가동하십시오.
)
echo.
pause
exit /b %RC%
