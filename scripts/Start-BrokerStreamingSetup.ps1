#requires -Version 7.2
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
$parameters=[Console]::In.ReadToEnd()|ConvertFrom-Json -AsHashtable
& (Join-Path $PSScriptRoot 'Start-StreamingSession.ps1') @parameters
