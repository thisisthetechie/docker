# escape=`

# Modified from Jonathan Muller's solution: https://blog.drylm.org/posts/rabbitmq_windows_container.html

# Setup shared variables
ARG ERLANG_VERSION=21.1
ARG RABBITMQ_VERSION=3.7.8

# Use server core to support erlang install
FROM microsoft/windowsservercore as source

# Setup PowerShell as default Run Shell
SHELL ["PowerShell.exe", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'Continue'; "]

# Environment Variables (ARGs needed to see outer scoped ARGs)
ARG ERLANG_VERSION
ARG RABBITMQ_VERSION
ARG RABBITMQ_VERSIONP

ENV ERLANG_VERSION=$ERLANG_VERSION `
    ERLANG_HOME=c:\erlang `
    RABBITMQ_HOME=c:\rabbitmq `
    RABBITMQ_VERSION=$RABBITMQ_VERSION `
    RABBITMQ_VERSIONP=$RABBITMQ_VERSIONP

# Install VC Redistributable
RUN Write-Host ('Downloading Visual C++ Redistributable Package'); `
    Invoke-WebRequest -Uri https://download.microsoft.com/download/9/3/F/93FCF1E7-E6A4-478B-96E7-D4B285925B00/vc_redist.x64.exe -OutFile vcredist.exe -UseBasicParsing; `
    Start-Process .\vcredist.exe -ArgumentList '/install', '/quiet', '/norestart' -NoNewWindow -Wait;

# Install Erlang OTP
RUN Write-Host -Object 'Downloading Erlang OTP' ; `
    $erlangInstaller = Join-Path -Path $env:Temp -ChildPath 'otp_win64.exe' ; `
    Invoke-WebRequest -UseBasicParsing -Uri $('http://erlang.org/download/otp_win64_{0}.exe' -f $env:ERLANG_VERSION) -OutFile $erlangInstaller ; `
    Unblock-File -Path $erlangInstaller ; `
    Write-Host -Object 'Installing Erlang OTP' ; `
    Start-Process -NoNewWindow -Wait -FilePath $erlangInstaller -ArgumentList /S, /D=$env:ERLANG_HOME ; `
    Write-Host -Object 'Removing Erlang OTP Installer' ; `
    Remove-Item -Path $erlangInstaller ; `
    Write-Host -Object 'Done Installing Erlang OTP'

# Install RabbitMQ
RUN Write-Host 'Installing RabbitMQ' ; `
    Write-Host "Downloading RabbitMQ from https://github.com/rabbitmq/rabbitmq-server/releases/download/v$env:RABBITMQ_VERSION/rabbitmq-server-windows-$env:RABBITMQ_VERSION.zip" ; `
    $rabbitZip = Join-Path -Path $env:Temp -ChildPath 'rabbitmq.zip' ; `
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; `
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/rabbitmq/rabbitmq-server/releases/download/v$env:RABBITMQ_VERSION/rabbitmq-server-windows-$env:RABBITMQ_VERSION.zip" -OutFile $rabbitZip ; `
    Unblock-File -Path $rabbitZip ; `
    Write-Host -Object 'Extracting RabbitMQ' ; `
    Expand-Archive -Path $rabbitZip -DestinationPath c:\ ; `
    Rename-Item c:\rabbitmq_server-$env:RABBITMQ_VERSION $env:RABBITMQ_HOME ; `
    Write-Host -Object 'Removing RabbitMQ Zip' ; `
    Remove-Item -Path $rabbitZip ; `
    Write-Host -Object 'Done Installing RabbitMQ'

# Start from nano server (the version MUST be the same version as your host)
# I spent a LONG time trying to get this working on anything other than 1709 - only to discover this would not work on anything other than 
#   the version of windows running on the Docker Host (it will not warn you of this, Erlang simply won't run)
# This MAY work if you remove the version, YMMV, in my case I had to explicitly set the version number

FROM microsoft/nanoserver:1709 AS final

# We need to reference a user, otherwise paths and environment variables won't work properly
USER Administrator

# Environment Variables (ARGs needed to see outer scoped ARGs)
ARG RABBITMQ_VERSION
ARG RABBITMQ_BASE=c:\data
ARG ERLANG_VERSION
ENV ERLANG_HOME=c:\erlang `
    RABBITMQ_HOME=c:\rabbitmq `
    RABBITMQ_BASE=$RABBITMQ_BASE `
    ERLANG_VERSION=$ERLANG_VERSION `
    RABBITMQ_VERSION=$RABBITMQ_VERSION

# set HOMEDRIVE and HOMEPATH (required to create erlang cookie)
ENV HOMEDRIVE=c: `
    HOMEPATH=\Users\Administrator
RUN SETX PATH %PATH%;%RABBITMQ_HOME%;%RABBITMQ_BASE%;%ERLANG_HOME% /M

# setup persistent folders and add Crash Dump location
VOLUME $RABBITMQ_BASE
ENV ERL_CRASH_DUMP=${RABBITMQ_BASE}\erl.dump

# setup folders and paths
WORKDIR $RABBITMQ_HOME\sbin

# Copy erlang and c++ runtime from windows core image
COPY --from=source $ERLANG_HOME $ERLANG_HOME
COPY --from=source $RABBITMQ_HOME $RABBITMQ_HOME
COPY --from=source C:\windows\system32\mfc140.dll C:\windows\system32
COPY --from=source C:\windows\system32\mfc140u.dll C:\windows\system32
COPY --from=source C:\windows\system32\mfcm140.dll C:\windows\system32
COPY --from=source C:\windows\system32\mfcm140u.dll C:\windows\system32
COPY --from=source C:\windows\system32\vcamp140.dll C:\windows\system32
COPY --from=source C:\windows\system32\vccorlib140.dll C:\windows\system32
COPY --from=source C:\windows\system32\vcomp140.dll C:\windows\system32
COPY --from=source C:\windows\system32\msvcp140.dll C:\windows\system32
COPY --from=source C:\windows\system32\vcruntime140.dll C:\windows\system32
COPY --from=source C:\windows\system32\concrt140.dll C:\windows\system32

COPY entrypoint.cmd .

# create roaming folder
RUN mkdir %APPDATA%\RabbitMQ

# Create link to CONFIG file
ENV RABBITMQ_CONFIG_FILE=$RABBITMQ_HOME\rabbitmq.conf

# Populate Config File (QUEUE_USER and QUEUE_PASS must be passed in as --build-arg at build time)
ARG QUEUE_PASS
ARG QUEUE_USER
WORKDIR $RABBITMQ_HOME\etc
RUN echo default_user=%QUEUE_USER% >> %RABBITMQ_CONFIG_FILE%
RUN echo default_pass=%QUEUE_PASS% >> %RABBITMQ_CONFIG_FILE%
RUN echo loopback_users=none >> %RABBITMQ_CONFIG_FILE%

# Ports
# 4369: epmd, a peer discovery service used by RabbitMQ nodes and CLI tools
# 5672: used by AMQP 0-9-1 and 1.0 clients without TLS
# 5671: used by AMQP 0-9-1 and 1.0 clients with TLS
# 25672: used by Erlang distribution for inter-node and CLI tools communication and is allocated from a dynamic range (limited to a single port by default, computed as AMQP port + 20000).
# 15672: HTTP API clients and rabbitmqadmin (only if the management plugin is enabled)
# 61613: STOMP clients without TLS (only if the STOMP plugin is enabled)
# 61614: STOMP clients with TLS (only if the STOMP plugin is enabled)
# 1883: MQTT clients without TLS, if the MQTT plugin is enabled
# 8883: MQTT clients with TLS, if the MQTT plugin is enabled
# 15674: STOMP-over-WebSockets clients (only if the Web STOMP plugin is enabled)
# 15675: MQTT-over-WebSockets clients (only if the Web MQTT plugin is enabled)
EXPOSE 4369 5672 5671 25672 15672 61613 61614 1883 8883 15674 15675

# setup folders and paths
WORKDIR $RABBITMQ_HOME\sbin

# install the service within erl
RUN rabbitmq-service.bat install

# run external command when container starts to allow for additional setup
ENTRYPOINT entrypoint.cmd


###################################################
# Your EntryPoint.cmd file is a simple enough file:
###################################################
#
# @echo off
#
# if not exist %RABBITMQ_BASE%\enabled_plugins (
#     call rabbitmq-plugins.bat enable rabbitmq_management --offline
# )
# call rabbitmq-server.bat

###################################################
# Build Command Example:
#
# docker build -t rabbitmq --build-arg QUEUE_USER=[user] --build-arg QUEUE_PASS=[pass] .
###################################################
