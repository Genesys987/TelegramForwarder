# Python Telegram signal forwarder

Uses Pipenv
https://packaging.python.org/en/latest/tutorials/managing-dependencies/

Get Telegram API key at https://my.telegram.org/.

```bash
#copy config
cp .env.example .env
# !! At this point, add your config to .env !!
# install pipenv
python -m pip install --user pipenv
# install project dependencies
pipenv install
# run app (using .env)
pipenv run python main.py
# run app (using custom env file)
pipenv run python main.py .env.gergely
# run unit tests
pipenv run python -m unittest discover -s test
# run formatter
pipenv run ruff format
```
