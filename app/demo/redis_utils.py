import os
import redis
REDIS_URL = os.environ.get('REDIS_URL','redis://redis:6379/0')
r = redis.Redis.from_url(REDIS_URL)
