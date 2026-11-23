@echo off
setlocal
rem Run from the staged Mods/opencj/cod4 directory.
set "OPENCJ_COD4_DIR=%cd%"
set "OPENCJ_DIR=%OPENCJ_COD4_DIR%\.."
set "ROOT_DIR=%OPENCJ_COD4_DIR%\..\..\.."
set "RAW_DIR=%ROOT_DIR%\raw"
set "BIN_DIR=%ROOT_DIR%\bin"
set "ZONE_SOURCE_DIR=%ROOT_DIR%\zone_source"
set "ZONE_DIR=%ROOT_DIR%\zone"
set "OPENCJ_IWD=z_opencj.iwd"
set "OPENCJ_FF=mod.ff"

rem Check tools and staged inputs before invalidating any previous output.
if not defined OPENCJ_7ZIP (
    set "OPENCJ_7ZIP=7z.exe"
)
"%OPENCJ_7ZIP%" i >nul 2>&1
if errorlevel 1 (
    echo 7-Zip is unavailable. Install it and add 7z.exe to PATH, 1>&2
    echo or set OPENCJ_7ZIP to its full executable path. 1>&2
    exit /B 1
)
if not exist "%BIN_DIR%\linker_pc.exe" (
    echo Missing Mod Tools linker. 1>&2
    exit /B 1
)
if not exist "%OPENCJ_COD4_DIR%\mod.csv" (
    echo Missing staged mod.csv. 1>&2
    exit /B 1
)
if not exist "%OPENCJ_COD4_DIR%\licenses\" (
    echo Missing staged license notices. 1>&2
    exit /B 1
)
for %%D in ("%RAW_DIR%" "%ZONE_SOURCE_DIR%" "%ZONE_DIR%\english") do (
    if not exist "%%~D\" (
        echo Missing Mod Tools directory: %%~D 1>&2
        exit /B 1
    )
)
set /A asset_folder_count=0
for %%D in (opencj animtrees english fx images maps material_properties materials info mp soundaliases sound ui ui_mp weapons vision xanim xmodel xmodelparts xmodelsurfs) do (
    if exist "%%D\" (
        set /A asset_folder_count+=1 >nul
    )
)
if "%asset_folder_count%"=="0" (
    echo No fastfile asset folders were found. 1>&2
    exit /B 1
)

rem A failed build must not leave an old package that looks newly built.
for %%F in ("%OPENCJ_DIR%\%OPENCJ_IWD%" "%OPENCJ_DIR%\%OPENCJ_FF%" "%ZONE_DIR%\english\%OPENCJ_FF%") do (
    if exist "%%~F" (
        del /Q "%%~F"
        if errorlevel 1 (
            echo Failed to remove an old build output. 1>&2
            goto fail
        )
    )
)

rem Keep each copy failure visible; a later successful copy must not hide it.
for %%D in (opencj animtrees english fx images maps material_properties materials info mp soundaliases sound ui ui_mp weapons vision xanim xmodel xmodelparts xmodelsurfs) do (
    if exist "%%D\" (
        xcopy "%%D" "%RAW_DIR%\%%D" /E /I /Y
        if errorlevel 1 (
            echo Failed to copy %%D into raw assets. 1>&2
            goto fail
        )
    )
)
copy /Y "%OPENCJ_COD4_DIR%\mod.csv" "%ZONE_SOURCE_DIR%\mod.csv" >nul
if errorlevel 1 (
    echo Failed to copy mod.csv. 1>&2
    goto fail
)

pushd "%BIN_DIR%"
if errorlevel 1 (
    echo Failed to enter the Mod Tools bin directory. 1>&2
    goto fail
)
linker_pc.exe -language english -compress -cleanup mod
set "linker_exit_code=%errorlevel%"
popd
if not "%linker_exit_code%"=="0" (
    echo Linker failed with exit code %linker_exit_code%. 1>&2
    goto fail
)
if not exist "%ZONE_DIR%\english\%OPENCJ_FF%" (
    echo Linker produced no mod.ff. 1>&2
    goto fail
)

copy /Y "%ZONE_DIR%\english\%OPENCJ_FF%" "%OPENCJ_DIR%\%OPENCJ_FF%" >nul
if errorlevel 1 (
    echo Failed to copy the compiled fastfile. 1>&2
    goto fail
)
for %%D in (images weapons licenses) do (
    if exist "%%D\" (
        "%OPENCJ_7ZIP%" a -r -tzip "%OPENCJ_DIR%\%OPENCJ_IWD%" "%%D"
        if errorlevel 1 (
            echo Failed to package %%D into the IWD. 1>&2
            goto fail
        )
    )
)
echo Mod created successfully!
exit /B 0

:fail
rem These are this build's output names; never remove any source directories.
for %%F in ("%OPENCJ_DIR%\%OPENCJ_IWD%" "%OPENCJ_DIR%\%OPENCJ_FF%") do (
    if exist "%%~F" (
        del /Q "%%~F"
    )
)
exit /B 1
