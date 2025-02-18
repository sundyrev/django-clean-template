Это скрипт для установки чистого шаблона Django проекта, с которым можно быстро начать разработку. В шаблон входит конфиг Systemd, Nginx, Gunicorn.

Примерная структура шаблона Django проекта:

```lua
project_directory/
├── conf/
│   ├── nginx/
│	│   └── project_name.nginx.conf
│   ├── gunicorn/
│   │   ├── project_name.gunicorn.socket
│   │   └── project_name.gunicorn.service
│   └── env_vars/
│		├── local.env
│		└── production.env
├── env/
├── log/
│   ├── gunicorn.log
│   ├── nginx.log
│   └── django.log
└── project_name/
    ├── apps/
    │   └── .../
    ├── config/
    │   ├── __init__.py
    │   ├── asgi.py
    │   ├── settings.py
    │   ├── urls.py
    │   └── wsgi.py
    ├── templates/
    │   └── base.html
    ├── jinja2/
    │   └── j2.index.html
    ├── media/
    ├── manage.py
    ├── README.md
	└── requirements/
		├── base.txt
		├── local.txt
		└── production.txt
```

Будет необходимо указать Python интерпретатор, названиe домена и название проекта. Для установки запустите:

```zsh
./install.sh
```

В файле с переменными окружения (`/conf/env_vars`) заполните настройки подключения к базе данных.

Проект использует `pip-tools` для управления зависимостями. При необходимости добавить новую зависимость:

```zsh
echo "new-package>=1.0.0" >> requirements/local.in
pip-compile requirements/local.in
pip-sync requirements/local.txt
```

Посмотреть статус службы gunicorn:

```zsh
sudo systemctl status project_name.gunicorn.service
```

После изменения systemd конфига надо перечитать его и затем перезапустить юнит:

```zsh
sudo systemctl daemon-reload
sudo systemctl restart project_name.gunicorn.service
```

Для остановки служб и удаления шаблона Django проекта, запустите:

```zsh
./delete.sh
```
