from flask import render_template
from app import app


@app.route('/')
@app.route('/index')
def index():
    user = User.query.filter_by(nickname='pekask').first()

    # If no user (migration not completed), 
    # to not get error 500, placehoder (optional)
    if not user:
        user = {'nickname': 'Guest'}

    # Получаем все посты
    posts = Post.query.all()

    return render_template('index.html',
                           title='Home',
                           user=user,
                           posts=posts)

