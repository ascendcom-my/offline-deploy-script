@echo off
setlocal enabledelayedexpansion

:: =============================================================================
::  Laravel Project Deployment Script for Windows
:: =============================================================================
::
::  This script automates setting up a Laravel development environment on Windows.
::
::  Usage:
::    deploy.bat "your_git_repository_url"
::
:: =============================================================================

:: --- 1. Administrative Privileges Check ---
:: This block checks for Admin rights and re-launches the script if needed.
:: A UAC prompt will appear if the script is not run as Administrator.
echo Checking for administrative privileges...
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo.
    echo [ACTION REQUIRED] Requesting administrative privileges to run installers...
    echo Please click "Yes" on the UAC prompt.
    powershell -Command "Start-Process '%~0' -ArgumentList '%*' -Verb runAs" -Wait
    exit /b
)
echo [SUCCESS] Running with administrative privileges.
echo.

:: --- Script continues with Admin rights from here ---
cd /d "%~dp0"

:: --- 1. Configuration ---
echo [STEP 1/8] Setting up configuration variables...
set "HERD_INSTALLER_URL=https://herd.laravel.com/download/windows"
set "GIT_INSTALLER_URL=https://github.com/git-for-windows/git/releases/download/v2.45.2.windows.1/Git-2.45.2-64-bit.exe"
set "DBNGIN_INSTALLER_URL=https://dbngin.com/release/windows/dbngin_latest"
set "DOWNLOADS_DIR=%USERPROFILE%\Downloads\deployment_tools"
set "HERD_PROJECTS_DIR=%USERPROFILE%\Herd"

:: The API endpoint to receive the public SSH key.
set "PUBLIC_KEY_API_ENDPOINT=https://stephenkhoo.com/api/ssh-public-key"

:: Check for repository URL argument
if "%~1"=="" (
    echo.
    echo [ERROR] Missing repository URL.
    echo Usage: %0 "git@github.com:user/repo.git"
    exit /b 1
)
set "REPO_URL=%~1"
echo    - Repository URL: %REPO_URL%
echo    - Public Key API: %PUBLIC_KEY_API_ENDPOINT%
echo [SUCCESS] Configuration set.
echo.


:: --- 2. Download Tools ---
echo [STEP 2/8] Downloading required tools...
if not exist "%DOWNLOADS_DIR%" mkdir "%DOWNLOADS_DIR%"
echo    - Downloads will be saved to: %DOWNLOADS_DIR%

:: Git (with silent install)
echo.
echo    - Downloading and silently installing Git...
if not exist "%DOWNLOADS_DIR%\git-installer.exe" (
    curl -L "%GIT_INSTALLER_URL%" -o "%DOWNLOADS_DIR%\git-installer.exe"
)
start /wait "" "%DOWNLOADS_DIR%\git-installer.exe" /VERYSILENT /NORESTART
echo    - Git installation complete.

:: Laravel Herd (Manual install)
echo.
echo    - Downloading Laravel Herd...
if not exist "%DOWNLOADS_DIR%\herd-installer.exe" (
    curl -L "%HERD_INSTALLER_URL%" -o "%DOWNLOADS_DIR%\herd-installer.exe"
)
echo [ACTION REQUIRED] The Laravel Herd installer will now open.
echo Please complete the installation manually. The script will wait.
start /wait "" "%DOWNLOADS_DIR%\herd-installer.exe"
echo    - Laravel Herd installation complete.

:: DBngin (Manual install)
echo.
echo    - Downloading DBngin...
if not exist "%DOWNLOADS_DIR%\dbngin-installer.exe" (
    curl -L "%DBNGIN_INSTALLER_URL%" -o "%DOWNLOADS_DIR%\dbngin-installer.exe"
)
echo [ACTION REQUIRED] The DBngin installer will now open.
echo Please complete the installation manually. The script will wait.
start /wait "" "%DOWNLOADS_DIR%\dbngin-installer.exe"
echo    - DBngin installation complete.
echo.

echo.
echo    - Updating session PATH to include newly installed tools...
set "PATH=%ProgramFiles%\Git\bin;%ProgramFiles%\Git\cmd;%LOCALAPPDATA%\Programs\Laravel Herd\bin;%LOCALAPPDATA%\Programs\Laravel Herd\bin\php;%PATH%"
echo [SUCCESS] Session PATH updated.
echo.

pause

:: --- 3. SSH Key Generation & Upload ---
echo [STEP 3/8] Handling SSH Key...

set "SSH_DIR=%USERPROFILE%\.ssh"
set "KEY_PATH=%SSH_DIR%\id_rsa"
set "PUB_KEY_PATH=%KEY_PATH%.pub"

if not exist "%SSH_DIR%" mkdir "%SSH_DIR%"
if not exist "%PUB_KEY_PATH%" (
    echo    - No existing SSH key found. Generating a new one...
    ssh-keygen -t rsa -b 4096 -N "" -f "%KEY_PATH%"
    echo    - SSH key generated.
) else (
    echo    - Existing SSH key found.
)

echo Your Public SSH Key:
type "%PUB_KEY_PATH%"


:: echo    - Uploading public key to the server...
:: set /p PUBLIC_KEY=<"%USERPROFILE%\.ssh\id_rsa.pub"
:: echo    - Sending key: !PUBLIC_KEY!

:: Using curl to send the key as a JSON payload
:: curl -X POST -H "Content-Type: application/json" -d "{\"key\":\"!PUBLIC_KEY!\"}" "%PUBLIC_KEY_API_ENDPOINT%"



echo.
echo [ACTION REQUIRED]
echo ===========================================================================
echo Your public SSH key has been sent. Please ensure it's authorized
echo on the server/Git provider before continuing.
echo ===========================================================================
pause
echo.

:: --- 4. Clone Project ---
echo [STEP 4/8] Cloning project from Git repository...
if not exist "%HERD_PROJECTS_DIR%" mkdir "%HERD_PROJECTS_DIR%"
cd /d "%HERD_PROJECTS_DIR%"
for %%i in ("%REPO_URL%") do set "PROJECT_DIR_NAME=%%~ni"
if exist "%PROJECT_DIR_NAME%" (
    echo    - Project directory '%PROJECT_DIR_NAME%' already exists. Skipping clone.
) else (
    git clone "%REPO_URL%"
    if errorlevel 1 (
        echo [ERROR] Git clone failed. Check your URL and SSH key permissions.
        exit /b 1
    )
)
cd /d "%HERD_PROJECTS_DIR%\%PROJECT_DIR_NAME%"
echo [SUCCESS] Project cloned into %CD%.
echo.


:: --- 5. Install Dependencies ---
echo [STEP 5/8] Installing project dependencies...
echo    - Installing Composer packages...
composer install --no-interaction --prefer-dist --optimize-autoloader
if errorlevel 1 (echo [ERROR] Composer install failed. && exit /b 1)

echo    - Setting up .env file...
copy .env.example .env
php artisan key:generate

echo    - Installing NPM packages and building assets...
npm install
if errorlevel 1 (echo [ERROR] npm install failed. && exit /b 1)
npm run build
if errorlevel 1 (echo [ERROR] npm run build failed. && exit /b 1)
echo [SUCCESS] Dependencies installed.
echo.


:: --- 6. Database Setup ---
echo [STEP 6/8] Setting up database connection...

set "DB_DATABASE=%PROJECT_DIR_NAME%"
set "DB_USERNAME=root"
set "DB_PASSWORD="

echo    - Searching for MySQL client from DBngin...
set "MYSQL_CLI_PATH="
if exist "%USERPROFILE%\.dbngin\mysql" (
    for /r "%USERPROFILE%\.dbngin\mysql" %%f in (mysql.exe) do if not defined MYSQL_CLI_PATH set "MYSQL_CLI_PATH=%%f"
)

if not defined MYSQL_CLI_PATH (
    echo [WARNING] Could not find mysql.exe in the default DBngin path.
    echo Searching Program Files as a fallback...
    for /r "%ProgramFiles%" %%f in (mysql.exe) do if not defined MYSQL_CLI_PATH set "MYSQL_CLI_PATH=%%f"
)

if not defined MYSQL_CLI_PATH ( echo [ERROR] Could not find mysql.exe. && exit /b 1 )
echo    - Found MySQL client at: !MYSQL_CLI_PATH!

echo    - Creating database '%DB_DATABASE%'...
set "PASSWORD_ARG="
if defined DB_PASSWORD set "PASSWORD_ARG=-p%DB_PASSWORD%"
"!MYSQL_CLI_PATH!" -u %DB_USERNAME% %PASSWORD_ARG% -e "CREATE DATABASE IF NOT EXISTS \`%DB_DATABASE%\`;"
if errorlevel 1 ( echo [ERROR] Failed to create database. Check if service is running. && exit /b 1)

pause

echo    - Updating .env file with database credentials...
(
    for /f "usebackq tokens=*" %%a in (".env") do (
        set "line=%%a"
        if "!line:DB_DATABASE=!" neq "!line!" (
            echo DB_DATABASE=%DB_DATABASE%
        ) else if "!line:DB_USERNAME=!" neq "!line!" (
            echo DB_USERNAME=%DB_USERNAME%
        ) else if "!line:DB_PASSWORD=!" neq "!line!" (
            echo DB_PASSWORD=%DB_PASSWORD%
        ) else (
            echo !line!
        )
    )
) > .env.tmp
move /y .env.tmp .env > nul

echo    - Running database migrations...
php artisan migrate
if errorlevel 1 (
    echo [ERROR] Migration failed. Check your .env credentials and database server status.
    exit /b 1
)
echo [SUCCESS] Database configured and migrated.
echo.

:: --- 7. Run Tests ---
echo [STEP 7/8] Running tests to verify installation...
php artisan test
if errorlevel 1 (
    echo [WARNING] Tests failed. The application might have issues.
) else (
    echo [SUCCESS] Tests passed!
)
echo.

:: --- 8. Touching up ---
echo [STEP 8/8] Touching up
php artisan storage:link

echo.


:: --- Finalization ---
echo =============================================================================
echo DEPLOYMENT SCRIPT FINISHED!
echo =============================================================================
echo.
echo.
echo Setup completed!
set "PROJECT_URL=http://%PROJECT_DIR_NAME%.test"
echo Your Laravel project is ready!
echo You can access it at: %PROJECT_URL%
echo.

:: --- Find Chrome executable path ---
set "CHROME_PATH="
echo    - Searching for Google Chrome executable...

if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" (
    set "CHROME_PATH=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
) else if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" (
    set "CHROME_PATH=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
) else if exist "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe" (
    set "CHROME_PATH=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
)

if not defined CHROME_PATH (
    echo [WARNING] Could not find Google Chrome. Skipping startup script creation.
) else (
    echo    - Found Chrome at: !CHROME_PATH!

    :: --- Produce a bat file to install for startup ---
    set "STARTUP_SCRIPT_PATH=%USERPROFILE%\Desktop\startup.bat"
    echo    - Creating startup script at: !STARTUP_SCRIPT_PATH!
    (
        echo @echo off
        echo :: This script launches the application in Kiosk mode after a delay.
        echo echo Waiting 10 seconds for services ^(Herd, DBngin^) to initialize...
        echo timeout /t 10
        echo echo Terminating Windows Explorer...
        echo taskkill /f /im explorer.exe
        echo echo Launching application: !PROJECT_URL!
        echo start "" "!CHROME_PATH!" --kiosk --disable-pinch "!PROJECT_URL!"
    ) > "!STARTUP_SCRIPT_PATH!"

    :: --- Create a shortcut and place it in shell:startup ---
    set "SHORTCUT_NAME=%PROJECT_DIR_NAME% Kiosk Launcher"
    set "STARTUP_FOLDER=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
    set "SHORTCUT_PATH=!STARTUP_FOLDER!\!SHORTCUT_NAME!.lnk"

    echo    - Creating shortcut in the Startup folder...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut('!SHORTCUT_PATH!'); $s.TargetPath = '!STARTUP_SCRIPT_PATH!'; $s.Save()"

    if errorlevel 1 (
        echo [ERROR] Failed to create the startup shortcut.
    ) else (
        echo [SUCCESS] Startup script and shortcut created.
    )
)
echo.
endlocal




