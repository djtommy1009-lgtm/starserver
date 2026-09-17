@echo off
setlocal EnableExtensions
chcp 65001 >nul
title R197 테스트 서버 원복

echo 테스트 서버를 정상 종료한 상태에서만 진행합니다.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0R197_테스트서버_원복.ps1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo [실패] 원복되지 않았습니다. 원복 기록과 오류를 확인하십시오.
) else (
    echo [완료] R197 적용 전 테스트 JAR으로 복구했습니다.
)
echo.
pause
exit /b %RC%
