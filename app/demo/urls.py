from django.urls import path
from . import views

app_name = "demo"

urlpatterns = [
    path("", views.home, name="home"),
    path("create-person/", views.create_person, name="create_person"),
    path("trigger-add/", views.trigger_add, name="trigger_add"),
    path("task-status/", views.task_status, name="task_status"),
    path("redis-set/", views.redis_set, name="redis_set"),
    path("redis-get/", views.redis_get, name="redis_get"),
]