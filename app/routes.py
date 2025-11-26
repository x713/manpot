from flask import render_template
from app import app

jokes = ['Чем отличается басист от пиццы?\nПицца может накормить семью из четырех человек.',
        'Как заставить басиста играть тише?\nПоложите перед ним ноты.\nБасист подходит к дирижеру после репетиции:\n'
        '— Простите, я сегодня немного фальшивил?\n— Нет. Ты промахивался на долю такта. Но почему ты все время думал, что фальшивил?\n— Потому что я играл на четверть тона выше, чтобы было не так заметно!'            
        ]
authors = ['John', 'Susan', 'Jenny']

def get_data():
    if not User.query.first():
        user = User(nickname='pekask')
        db.session.add(user)
        p1 = Post(body=jokes[0], author=authors[0])
        p2 = Post(body=jokes[1], author=authors[1])
        p3 = Post(body=jokes[2], author=authors[2])
        db.session.commit()
        
     # Реальный запрос к БД
    posts = Post.query.all()
    # Предполагаем, что показываем для первого пользователя
    user = User.query.first() 

    return posts, user


@app.route('/')
@app.route('/index')
def index():

    posts, users = get_data()

    return render_template('index.html',
                           title='Home',
                           user=user,
                           posts=posts)

