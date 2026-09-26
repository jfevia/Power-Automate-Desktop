# Power-Automate-Desktop

The daily or manually dispatched release workflow compares the Microsoft installer SHA-256 with the latest release asset. It skips unchanged installers, runs the Windows release job only when the installer changes, and never publishes from pull requests. Existing version tags are skipped without failing the workflow.

Trigger it manually with `gh workflow run release.yml --ref main`. Run the workflow tests with PowerShell 7, Pester, and `powershell-yaml`: `Invoke-Pester -Script .\tests\release.Tests.ps1`.