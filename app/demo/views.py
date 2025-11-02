from django.shortcuts import render, redirect
from django.http import JsonResponse, HttpResponseBadRequest
from django.urls import reverse
from django.views.decorators.http import require_POST
from celery.result import AsyncResult

from .forms import PersonForm
from .models import Person
from .tasks import add
from .redis_utils import r

def home(request):
    # DB: list people
    people = Person.objects.order_by("-created_at")[:10]
    form = PersonForm()
    return render(request, "demo/home.html", {"form": form, "people": people})

@require_POST
def create_person(request):
    form = PersonForm(request.POST)
    if form.is_valid():
        form.save()
        return redirect(reverse("demo:home"))
    # if invalid, show same page with errors
    people = Person.objects.order_by("-created_at")[:10]
    return render(request, "demo/home.html", {"form": form, "people": people})

@require_POST
def trigger_add(request):
    try:
        x = int(request.POST.get("x", ""))
        y = int(request.POST.get("y", ""))
    except ValueError:
        return HttpResponseBadRequest("x and y must be integers")
    res = add.delay(x, y)
    return JsonResponse({"task_id": res.id, "status": "queued"})

def task_status(request):
    task_id = request.GET.get("task_id")
    if not task_id:
        return HttpResponseBadRequest("Missing task_id")
    ar = AsyncResult(task_id)
    payload = {"task_id": task_id, "state": ar.state}
    if ar.state == "SUCCESS":
        payload["result"] = ar.result
    elif ar.state == "FAILURE":
        payload["error"] = str(ar.info)
    return JsonResponse(payload)

def redis_set(request):
    key = request.GET.get("key", "test:key")
    value = request.GET.get("value", "hello")
    r.set(key, value)
    return JsonResponse({"ok": True, "key": key, "value": value})

def redis_get(request):
    key = request.GET.get("key", "test:key")
    val = r.get(key)
    if val is None:
        return JsonResponse({"ok": True, "key": key, "value": None})
    return JsonResponse({"ok": True, "key": key, "value": val.decode("utf-8")})