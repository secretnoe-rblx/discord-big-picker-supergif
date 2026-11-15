@echo off
chcp 65001 >nul
title BigPicker for Discord
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
