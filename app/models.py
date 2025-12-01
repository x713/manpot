from app import db

class User(db.Model):
    # CRITICAL FIX: Explicitly setting the table name to 'users' to avoid 
    # conflict with the reserved keyword 'user' in PostgreSQL.
    __tablename__ = 'users' 
    
    id = db.Column(db.Integer, primary_key=True)
    nickname = db.Column(db.String(64), index=True, unique=True)
    
    # Update relationship to point to the new table name 'users.id'
    posts = db.relationship('Post', backref='author', lazy='dynamic')

    def __repr__(self):
        return f'<User {self.nickname}>'


class Post(db.Model):
    __tablename__ = 'posts'

    id = db.Column(db.Integer, primary_key=True)
    body = db.Column(db.String(500))
    
    # Update ForeignKey to reference the new table name 'users.id'
    user_id = db.Column(db.Integer, db.ForeignKey('users.id')) 
    
    def __repr__(self):
        return f'<Post {self.body}>'