@echo off
setlocal EnableExtensions
chcp 65001 >nul
title R197 자동사냥 전투 테스트 로그 수집

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0R197_테스트로그_수집.ps1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo [실패] 테스트 로그 수집 중 오류가 발생했습니다.
) else (
    echo [완료] 바탕화면에 R197 테스트 로그 ZIP을 생성했습니다.
)
echo.
pause
exit /b %RC%
