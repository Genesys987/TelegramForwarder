# Python Telegram signal forwarder

Uses Pipenv
https://packaging.python.org/en/latest/tutorials/managing-dependencies/

Get Telegram API key at https://my.telegram.org/.

```bash
#copy config
cp .env.example .env
# !! At this point, add your config to .env !!
# install pipenv
python3 -m pip install --user pipenv
# install project dependencies
pipenv install
# run app
pipenv run python main.py
# run unit tests
pipenv run python -m unittest
```
