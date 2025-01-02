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
│		└── deploy.env
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
	└── requirements.txt
```

Будет необходимо указать Python интерпретатор, названиe домена и название проекта. Для установки запустите:

```zsh
./install.sh
```

В конфиге Django заполните настройки базы данных (`/config/settings.py`).

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
