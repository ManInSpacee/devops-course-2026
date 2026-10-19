# Конфигурация виртуальной машины devops-vm

Документ описывает конфигурацию так, чтобы её можно было восстановить с чистой установки (снимок `01-clean-install`). Команды с пометкой **[VM]** выполняются на сервере, **[Хост]** — на хостовой системе (Windows, PowerShell).

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Имя | devops-vm |
| ОС | Ubuntu Server 24.04.5 LTS (64-bit) |
| Память | 2048 МБ |
| Процессор | 2 ядра |
| Диск | 25 ГБ, VDI, динамический; LVM-том расширен на весь диск |
| EFI | выключен |

Расширение логического тома после установки (по умолчанию установщик отдаёт `/` только половину диска):

```
# [VM]
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h /
```

Обновление системы:

```
# [VM]
sudo apt update && sudo apt upgrade -y
```

## 2. Сетевые интерфейсы

| Адаптер VirtualBox | Тип | Интерфейс в VM | Адрес | Назначение |
|---|---|---|---|---|
| Адаптер 1 | NAT | enp0s3 | 10.0.2.15/24 (DHCP) | выход в интернет, SSH через проброс портов |
| Адаптер 2 | Host-only (VirtualBox Host-Only Ethernet Adapter) | enp0s8 | 192.168.56.101/24 (DHCP) | прямой доступ с хоста, имя devops.local |

Адаптер Host-only на хосте должен иметь статический адрес `192.168.56.1/24`: VirtualBox → Файл → Инструменты → Менеджер сетей → адаптер → «Настроить адаптер вручную» → `192.168.56.1`, маска `255.255.255.0`. Иначе Windows назначает ему адрес `169.254.x.x`, и трафик к `192.168.56.101` не доходит до VM.

Если адаптер 2 добавлен после установки ОС, `enp0s8` будет в состоянии DOWN. Включить DHCP:

```
# [VM]
sudo nano /etc/netplan/50-cloud-init.yaml
```

```yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
    enp0s8:
      dhcp4: true
```

```
# [VM]
sudo chmod 600 /etc/netplan/50-cloud-init.yaml
sudo netplan apply
ip -brief address
```

## 3. Правило проброса портов

Адаптер 1 (NAT) → Дополнительно → Проброс портов:

| Имя | Протокол | Адрес хоста | Порт хоста | Адрес гостя | Порт гостя |
|---|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | — | 2222 |

На чистой установке, до раздела 5, порт гостя — **22**. После переноса SSH на порт 2222 (раздел 5) порт гостя меняется на **2222**.

## 4. Учётные записи

| Имя | UID | Группы | Аутентификация по SSH |
|---|---|---|---|
| student | 1000 | student, sudo, … | запрещена (`AllowUsers devops`), только консоль VM |
| devops | 1001 | devops, sudo, users | только по ключу ed25519 |

Создание пользователя:

```
# [VM], под student
sudo adduser devops
sudo usermod -aG sudo devops
groups devops
```

Ключ на хосте (отдельный, не тот, что для GitHub):

```
# [Хост]
ssh-keygen -t ed25519 -C "devops-vm-key" -f $env:USERPROFILE\.ssh\devops_vm
```

Передача открытого ключа на сервер (порт гостя в пробросе на этом этапе — 22):

```
# [Хост]
type $env:USERPROFILE\.ssh\devops_vm.pub | ssh devops@127.0.0.1 -p 2222 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Проверка прав (ожидается 700 и 600):

```
# [VM], под devops
chmod 700 ~/.ssh
stat -c '%a %n' ~/.ssh ~/.ssh/authorized_keys
```

Файл `C:\Users\<пользователь>\.ssh\config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

Проверка: `ssh devops` входит без запроса пароля.

## 5. Служба SSH

Основной файл `/etc/ssh/sshd_config` не изменяется, сохранена копия `/etc/ssh/sshd_config.backup`. Изменённые директивы — в `/etc/ssh/sshd_config.d/99-hardening.conf`.

Все шаги выполняются при открытой SSH-сессии, проверка — в новом терминале.

```
# [VM]
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo nano /etc/ssh/sshd_config.d/99-hardening.conf
```

```
Port 2222

PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30

AllowUsers devops

X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Файл `50-cloud-init.conf` содержит `PasswordAuthentication yes` и читается раньше `99-hardening.conf` (действует первое значение), поэтому строку нужно закомментировать:

```
# [VM]
sudo grep -r "PasswordAuthentication" /etc/ssh/sshd_config.d/
sudo sed -i 's/^PasswordAuthentication yes/#PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
```

Проверка синтаксиса и действующих значений:

```
# [VM]
sudo sshd -t && echo "Конфигурация корректна"
sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"
```

Ожидается: `port 2222`, `permitrootlogin no`, `passwordauthentication no`, `maxauthtries 3`, `allowusers devops`.

В Ubuntu 24.04 порт задаёт `ssh.socket`, а не директива `Port`. Переход на обычную службу:

```
# [VM]
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd        # ожидается 0.0.0.0:2222
```

После этого в VirtualBox изменить порт гостя в пробросе на **2222** (раздел 3).

Проверки с хоста в новом терминале:

```
# [Хост]
ssh devops                                                  # успех
ssh -p 2222 root@127.0.0.1                                  # Permission denied (publickey)
ssh -p 2222 -o PubkeyAuthentication=no devops@127.0.0.1     # Permission denied (publickey)
```

## 6. Правила межсетевого экрана

Политики по умолчанию: входящие — deny, исходящие — allow.

| Порт | Действие | Комментарий |
|---|---|---|
| 2222/tcp | LIMIT | SSH rate-limited |
| 80/tcp | ALLOW | HTTP |
| 443/tcp | ALLOW | HTTPS |

Порядок важен: правило для SSH создаётся до `ufw enable`.

```
# [VM]
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
sudo ufw status verbose
```

`ufw allow ssh` не использовать: имя `ssh` соответствует порту 22 по `/etc/services`.

## Имя узла

На хосте в `C:\Windows\System32\drivers\etc\hosts` (с правами администратора):

```
192.168.56.101    devops.local
```

```
# [Хост]
ipconfig /flushdns
ping devops.local
ssh devops.local
```

На сервере:

```
# [VM]
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f        # devops-vm.devops.local
```

## Проверка конфигурации

```
# [Хост]
scp scripts/audit.sh devops:~/
# [VM]
chmod +x ~/audit.sh
./audit.sh; echo $?      # все проверки OK, код 0
```

## 7. Снимки состояния

| Снимок | Момент создания |
|---|---|
| 02-keys-configured | 19.10.2026, после настройки входа по ключу (задание 1 ПР5) |
| 03-ssh-hardened | 19.10.2026, после усиления защиты SSH и включения UFW (задания 2–3 ПР5) |
| 01-clean-install | 19.10.2026, в конце ПР5; фактически содержит настроенную систему, а не чистую установку |
