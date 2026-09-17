@echo off
setlocal EnableExtensions
chcp 65001 >nul
title R197 자동사냥 원거리 단일행동 후보 JAR 빌드

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0R197_자동사냥_원거리단일행동_빌드.ps1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo [실패] 후보 JAR을 생성하지 않았습니다. 검수 보고서를 확인하십시오.
) else (
    echo [완료] 테스트 서버를 정상 종료한 뒤 2_R197_테스트서버_적용.cmd를 실행하십시오.
)
echo.
pause
exit /b %RC%
