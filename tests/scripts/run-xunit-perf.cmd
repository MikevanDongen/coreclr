@rem Licensed to the .NET Foundation under one or more agreements.
@rem The .NET Foundation licenses this file to you under the MIT license.
@rem See the LICENSE file in the project root for more information.

@echo off
@if defined _echo echo on

setlocal
  set ERRORLEVEL=
  set BENCHVIEW_RUN_TYPE=local
  set CORECLR_REPO=%CD%
  set TEST_FILE_EXT=exe
  set TEST_ARCH=x64
  set TEST_ARCHITECTURE=x64
  set TEST_CONFIG=Release
  set IS_SCENARIO_TEST=
  set USAGE_DISPLAYED=

  call :parse_command_line_arguments %*
  if defined USAGE_DISPLAYED exit /b %ERRORLEVEL%

  call :set_test_architecture || exit /b 1
  call :verify_core_overlay   || exit /b 1
  call :set_perf_run_log      || exit /b 1
  call :setup_sandbox         || exit /b 1

  call :run_cmd "%CORECLR_REPO%\Tools\dotnetcli\dotnet.exe" restore "%CORECLR_REPO%\tests\src\Common\PerfHarness\project.json"                                        || exit /b 1
  call :run_cmd "%CORECLR_REPO%\Tools\dotnetcli\dotnet.exe" publish "%CORECLR_REPO%\tests\src\Common\PerfHarness\project.json" -c Release -o "%CORECLR_REPO%\sandbox" || exit /b 1

  rem TODO: Remove the version of the package to copy. e.g.) if multiple version exist, then error out?
  call :run_cmd xcopy /sy "%CORECLR_REPO%\packages\Microsoft.Diagnostics.Tracing.TraceEvent\1.0.3-alpha-experimental\lib\native"\* . >> %RUNLOG%  || exit /b 1
  call :run_cmd xcopy /sy "%CORECLR_REPO%\bin\tests\Windows_NT.%TEST_ARCH%.%TEST_CONFIG%\Tests\Core_Root"\* . >> %RUNLOG%                         || exit /b 1

  rem find and stage the tests
  set /A "LV_FAILURES=0"
  for /R %CORECLR_PERF% %%T in (*.%TEST_FILE_EXT%) do (
    rem Skip known failures
    call :run_benchmark %%T || (
      set /A "LV_FAILURES+=1"
    )
  )

  rem optionally upload results to benchview
  if not [%BENCHVIEW_PATH%] == [] (
    call :upload_to_benchview || exit /b 1
  )

  rem Numbers are limited to 32-bits of precision (Int32.MAX == 2^32 - 1).
  if %LV_FAILURES% NEQ 0 (
    call :print_error %LV_FAILURES% benchmarks has failed.
    exit /b %LV_FAILURES%
  )

  exit /b %ERRORLEVEL%

:run_benchmark
rem ****************************************************************************
rem   Executes the xUnit Performance benchmarks
rem ****************************************************************************
setlocal
  set BENCHNAME=%~n1
  set BENCHDIR=%~p1
  set PERFOUT=perf-%BENCHNAME%
  set XMLOUT=%PERFOUT%.xml

  rem copy benchmark and any input files
  call :run_cmd xcopy /s %~1 . >> %RUNLOG%  || exit /b 1
  if exist "%BENCHDIR%*.txt" (
    call :run_cmd xcopy /s %BENCHDIR%*.txt . >> %RUNLOG%  || exit /b 1
  )

  set CORE_ROOT=%CORECLR_REPO%\sandbox

  rem setup additional environment variables
  if DEFINED TEST_ENV (
    if EXIST "%TEST_ENV%" (
        call "%TEST_ENV%"
    )
  )

  set BENCHNAME_LOG_FILE_NAME=%BENCHNAME%.log
  if defined IS_SCENARIO_TEST (
    call :run_cmd corerun.exe "%CORECLR_REPO%\sandbox\%BENCHNAME%.%TEST_FILE_EXT%" --perf:runid Perf 1>"%BENCHNAME_LOG_FILE_NAME%" 2>&1
  ) else (
    call :run_cmd corerun.exe PerfHarness.dll "%CORECLR_REPO%\sandbox\%BENCHNAME%.%TEST_FILE_EXT%" --perf:runid Perf 1>"%BENCHNAME_LOG_FILE_NAME%" 2>&1
  )

  IF %ERRORLEVEL% NEQ 0 (
    call :print_error corerun.exe exited with %ERRORLEVEL% code.
    if exist "%BENCHNAME_LOG_FILE_NAME%" type "%BENCHNAME_LOG_FILE_NAME%"
    exit /b 1
  )

  rem optionally generate results for benchview
  if not [%BENCHVIEW_PATH%] == [] (
    call :generate_results_for_benchview || exit /b 1
  ) else (
    type "%XMLOUT%" | findstr /i /c:"test name"
  )

  rem Save off the results to the root directory for recovery later in Jenkins
  call :run_cmd xcopy "Perf-%BENCHNAME%*.xml" "%CORECLR_REPO%\" || exit /b 1
  call :run_cmd xcopy "Perf-%BENCHNAME%*.etl" "%CORECLR_REPO%\" || exit /b 1

  exit /b 0

:parse_command_line_arguments
rem ****************************************************************************
rem   Parses the script's command line arguments.
rem ****************************************************************************
  IF /I [%~1] == [-testBinLoc] (
    set CORECLR_PERF=%CORECLR_REPO%\%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-scenarioTest] (
    set IS_SCENARIO_TEST=1
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-runtype] (
    set BENCHVIEW_RUN_TYPE=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-library] (
    set TEST_FILE_EXT=dll
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-uploadtobenchview] (
    set BENCHVIEW_PATH=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-arch] (
    set TEST_ARCHITECTURE=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-testEnv] (
    set TEST_ENV=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-configuration] (
    set TEST_CONFIG=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )

  if /I [%~1] == [-?] (
    call :USAGE
    exit /b 0
  )
  if /I [%~1] == [-help] (
    call :USAGE
    exit /b 0
  )
  if [%CORECLR_PERF%] == [] (
    call :USAGE
  )

  exit /b %ERRORLEVEL%

:set_test_architecture
rem ****************************************************************************
rem   Sets the test architecture.
rem ****************************************************************************
  IF /I [%TEST_ARCHITECTURE%] == [x86jit32] (
      set TEST_ARCH=x86
  ) ELSE (
      set TEST_ARCH=%TEST_ARCHITECTURE%
  )
  exit /b 0

:verify_core_overlay
rem ****************************************************************************
rem   Verify that the Core_Root folder exist.
rem ****************************************************************************
  set CORECLR_OVERLAY=%CORECLR_REPO%\bin\tests\Windows_NT.%TEST_ARCH%.%TEST_CONFIG%\Tests\Core_Root
  if NOT EXIST "%CORECLR_OVERLAY%" (
    call :print_error Can't find test overlay directory '%CORECLR_OVERLAY%'. Please build and run Release CoreCLR tests.
    exit /B 1
  )
  exit /b 0

:set_perf_run_log
rem ****************************************************************************
rem   Sets the script's output log file.
rem ****************************************************************************
  if NOT EXIST "%CORECLR_REPO%\bin\Logs" (
    call :print_error Cannot find the Logs folder '%CORECLR_REPO%\bin\Logs'.
    exit /b 1
  )
  set RUNLOG=%CORECLR_REPO%\bin\Logs\perfrun.log
  exit /b 0

:setup_sandbox
rem ****************************************************************************
rem   Creates the sandbox folder used by the script to copy binaries locally,
rem   and execute benchmarks.
rem ****************************************************************************
  if exist sandbox rd /s /q sandbox
  if exist sandbox call :print_error Failed to remove the sandbox folder& exit /b 1
  if not exist sandbox mkdir sandbox
  if not exist sandbox call :print_error Failed to create the sandbox folder& exit /b 1
  cd sandbox
  exit /b 0

:generate_results_for_benchview
rem ****************************************************************************
rem   Generates results for BenchView, by appending new data to the existing
rem   measurement.json file.
rem ****************************************************************************
  set BENCHVIEW_MEASUREMENT_PARSER=xunit
  if defined IS_SCENARIO_TEST set BENCHVIEW_MEASUREMENT_PARSER=xunitscenario

  set LV_MEASUREMENT_ARGS=
  set LV_MEASUREMENT_ARGS=%LV_MEASUREMENT_ARGS% %BENCHVIEW_MEASUREMENT_PARSER%
  set LV_MEASUREMENT_ARGS=%LV_MEASUREMENT_ARGS% "Perf-%BENCHNAME%.xml"
  set LV_MEASUREMENT_ARGS=%LV_MEASUREMENT_ARGS% --better desc
  set LV_MEASUREMENT_ARGS=%LV_MEASUREMENT_ARGS% --drop-first-value
  set LV_MEASUREMENT_ARGS=%LV_MEASUREMENT_ARGS% --append
  call :run_cmd py.exe "%BENCHVIEW_PATH%\measurement.py" %LV_MEASUREMENT_ARGS%
  IF %ERRORLEVEL% NEQ 0 (
    call :print_error Failed to generate BenchView measurement data.
    exit /b 1
  )
endlocal& exit /b %ERRORLEVEL%

:upload_to_benchview
rem ****************************************************************************
rem   Generates BenchView's submission data and upload it
rem ****************************************************************************
setlocal
  set LV_SUBMISSION_ARGS=
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --build ..\build.json
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --machine-data ..\machinedata.json
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --metadata ..\submission-metadata.json
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --group "CoreCLR"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --type "%BENCHVIEW_RUN_TYPE%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --config-name "%TEST_CONFIG%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --config Configuration "%TEST_CONFIG%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --config OS "Windows_NT"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --arch "%TEST_ARCHITECTURE%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --machinepool "PerfSnake"
  call :run_cmd py.exe "%BENCHVIEW_PATH%\submission.py" measurement.json %LV_SUBMISSION_ARGS%
  IF %ERRORLEVEL% NEQ 0 (
    call :print_error Creating BenchView submission data failed.
    exit /b 1
  )

  call :run_cmd py.exe "%BENCHVIEW_PATH%\upload.py" submission.json --container coreclr
  IF %ERRORLEVEL% NEQ 0 (
    call :print_error Uploading to BenchView failed.
    exit /b 1
  )
  exit /b %ERRORLEVEL%

:USAGE
rem ****************************************************************************
rem   Script's usage.
rem ****************************************************************************
  set USAGE_DISPLAYED=1
  echo run-xunit-perf.cmd -testBinLoc ^<path_to_tests^> [-library] [-arch] ^<x86^|x64^> [-configuration] ^<Release^|Debug^> [-uploadToBenchview] ^<path_to_benchview_tools^> [-runtype] ^<rolling^|private^> [-scenarioTest]
  echo/
  echo For the path to the tests you can pass a parent directory and the script will grovel for
  echo all tests in subdirectories and run them.
  echo The library flag denotes whether the tests are build as libraries (.dll) or an executable (.exe)
  echo Architecture defaults to x64 and configuration defaults to release.
  echo -uploadtoBenchview is used to specify a path to the Benchview tooling and when this flag is
  echo set we will upload the results of the tests to the coreclr container in benchviewupload.
  echo Runtype sets the runtype that we upload to Benchview, rolling for regular runs, and private for
  echo PRs.
  echo -scenarioTest should be included if you are running a scenario benchmark.
  exit /b %ERRORLEVEL%

:print_error
rem ****************************************************************************
rem   Function wrapper that unifies how errors are output by the script.
rem   Functions output to the standard error.
rem ****************************************************************************
  echo [%DATE%][%TIME:~0,-3%][ERROR] %*   1>&2
  exit /b %ERRORLEVEL%

:print_to_console
rem ****************************************************************************
rem   Sends text to the console screen, no matter what (even when the script's
rem   output is redirected). This can be useful to provide information on where
rem   the script is executing.
rem ****************************************************************************
  if defined _debug (
    echo [%DATE%][%TIME:~0,-3%] %* >CON
  )
  echo [%DATE%][%TIME:~0,-3%] %*
  exit /b %ERRORLEVEL%

:run_cmd
rem ****************************************************************************
rem   Function wrapper used to send the command line being executed to the
rem   console screen, before the command is executed.
rem ****************************************************************************
  if "%~1" == "" (
    call :print_error No command was specified.
    exit /b 1
  )

  call :print_to_console $ %*
  call %*
  exit /b %ERRORLEVEL%

:skip_failures
rem ****************************************************************************
rem   Skip known failures
rem ****************************************************************************
  IF /I [%TEST_ARCHITECTURE%] == [x86jit32] (
    IF /I "%~1" == "CscBench" (
      rem https://github.com/dotnet/coreclr/issues/11088
      exit /b 1
    )
    IF /I "%~1" == "SciMark2" (
      rem https://github.com/dotnet/coreclr/issues/11089
      exit /b 1
    )
  )
  exit /b 0
