<#
.SYNOPSIS
    Publish from dev repo to public repo (dual-repo pattern).
.PARAMETER Tag
    Version tag for the publish commit (e.g., v0.0.1-test).
.PARAMETER DryRun
    Preview only - do not push.
.PARAMETER Force
    Skip dirty-tree check.
#>
param(
    [string]$Tag,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$PublicRemote = 'public'
$PublishExcludeFile = '.publish-exclude'

# 1. Verify we are in a git repo with a public remote
$remotes = git remote 2>&1
if ($remotes -notcontains $PublicRemote) {
    throw "No '$PublicRemote' remote found. Configure with: git remote add $PublicRemote <url>"
}

# 2. Check for clean tree
if (-not $Force -and -not $DryRun) {
    $status = git status --porcelain
    if ($status) {
        throw "Working tree is dirty. Commit or stash changes first (or use -Force)."
    }
}

# 3. Read .publish-exclude
if (-not (Test-Path $PublishExcludeFile)) {
    throw "Missing $PublishExcludeFile. Cannot publish without exclusion list."
}
$excludePatterns = Get-Content $PublishExcludeFile | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() }
Write-Host "Loaded $($excludePatterns.Count) exclude patterns from $PublishExcludeFile" -ForegroundColor Cyan

# 4. Create temp dir and copy content
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) "publish-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
Write-Host "Staging to: $tmpDir" -ForegroundColor Cyan

# Copy all files except .git
$allFiles = git ls-files
$excluded = @()
$included = @()

foreach ($file in $allFiles) {
    $skip = $false
    foreach ($pattern in $excludePatterns) {
        $p = $pattern.TrimEnd('/')
        if ($file -eq $p -or $file -like "$p/*" -or $file -like "$p") {
            $skip = $true
            $excluded += $file
            break
        }
    }
    if (-not $skip) { $included += $file }
}

Write-Host "Files: $($included.Count) included, $($excluded.Count) excluded" -ForegroundColor Cyan

# 5. Verify no leaked artifacts (forbidden items)
$forbidden = @('.specify', 'specs', 'state', 'logs', 'backups', 'feedback',
    'governance', 'memory', 'metrics', 'snapshots', 'tmp', 'test-results',
    'coverage', 'seed', '.secrets.baseline', '.pii-allowlist', 'instructions',
    'devinstructions', '.private')

$leaked = @()
foreach ($file in $included) {
    foreach ($fb in $forbidden) {
        if ($file -eq $fb -or $file -like "$fb/*") {
            $leaked += $file
            break
        }
    }
}

if ($leaked.Count -gt 0) {
    Write-Host "`nFAILED: Leaked artifacts detected:" -ForegroundColor Red
    $leaked | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw "verifyNoLeakedArtifacts: FAILED. Update $PublishExcludeFile and retry."
}
Write-Host "verifyNoLeakedArtifacts: PASSED" -ForegroundColor Green

if ($DryRun) {
    Write-Host "`n=== DRY RUN ===" -ForegroundColor Yellow
    Write-Host "Would publish $($included.Count) files to $PublicRemote remote"
    Write-Host "`nIncluded files:" -ForegroundColor Cyan
    $included | ForEach-Object { Write-Host "  $_" }
    if ($excluded.Count -gt 0) {
        Write-Host "`nExcluded files:" -ForegroundColor DarkGray
        $excluded | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    return
}

# 6. Capture public remote URL before leaving repo dir
$publicUrl = git remote get-url $PublicRemote 2>$null
if (-not $publicUrl) {
    throw "Could not determine URL for '$PublicRemote' remote"
}

# 6b. Copy files to temp dir
foreach ($file in $included) {
    $dest = Join-Path $tmpDir $file
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item $file $dest
}

# 7. Create clean commit in temp dir
Push-Location $tmpDir
git init | Out-Null
git checkout -b main 2>&1 | Out-Null
git add -A | Out-Null

$commitMsg = if ($Tag) { "Publish $Tag from dev repo" } else { "Publish from dev repo" }
git commit -m $commitMsg | Out-Null

# 8. Push to public remote - temporarily unlock branch protection
# Parse org/repo from URL
$urlMatch = $publicUrl -match 'github\.com[/:]([^/]+)/([^/.]+)'
if ($urlMatch) {
    $pubOrg = $Matches[1]
    $pubRepo = $Matches[2]
    Write-Host "Temporarily unlocking $pubOrg/$pubRepo for publish..." -ForegroundColor Yellow
    
    # Disable lock_branch and enforce_admins
    $unlockJson = '{"lock_branch":false,"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":1,"dismiss_stale_reviews":true,"require_last_push_approval":true},"restrictions":null,"required_status_checks":null,"allow_force_pushes":true,"allow_deletions":false,"block_creations":true}'
    $unlockJson | gh api "repos/$pubOrg/$pubRepo/branches/main/protection" --method PUT --input - --silent 2>&1
    
    # Disable rulesets temporarily
    $rulesets = gh api "repos/$pubOrg/$pubRepo/rulesets" 2>$null | ConvertFrom-Json
    $rulesetIds = @()
    foreach ($rs in $rulesets) {
        $rulesetIds += $rs.id
        "{`"enforcement`":`"disabled`"}" | gh api "repos/$pubOrg/$pubRepo/rulesets/$($rs.id)" --method PUT --input - --silent 2>&1
    }
}

git remote add $PublicRemote $publicUrl
$env:PUBLISH_OVERRIDE = "1"
try {
    git push $PublicRemote main:main --force 2>&1
    if ($Tag) {
        git tag $Tag
        git push $PublicRemote --tags --force 2>&1
    }
} finally {
    $env:PUBLISH_OVERRIDE = ""
    # Re-lock branch protection
    if ($pubOrg -and $pubRepo) {
        Write-Host "Re-locking $pubOrg/$pubRepo..." -ForegroundColor Yellow
        $lockJson = '{"lock_branch":true,"enforce_admins":true,"required_pull_request_reviews":{"required_approving_review_count":1,"dismiss_stale_reviews":true,"require_last_push_approval":true},"restrictions":null,"required_status_checks":null,"allow_force_pushes":false,"allow_deletions":false,"block_creations":true}'
        $lockJson | gh api "repos/$pubOrg/$pubRepo/branches/main/protection" --method PUT --input - --silent 2>&1
        # Re-enable rulesets
        foreach ($rsId in $rulesetIds) {
            "{`"enforcement`":`"active`"}" | gh api "repos/$pubOrg/$pubRepo/rulesets/$rsId" --method PUT --input - --silent 2>&1
        }
        Write-Host "Branch protection and rulesets re-enabled" -ForegroundColor Green
    }
}
Pop-Location

Write-Host "`nPublish complete!" -ForegroundColor Green
if ($Tag) { Write-Host "Tag: $Tag" -ForegroundColor Green }

# Cleanup
Remove-Item $tmpDir -Recurse -Force



