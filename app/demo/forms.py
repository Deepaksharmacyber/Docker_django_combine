from django import forms
from .models import Person

class PersonForm(forms.ModelForm):
    class Meta:
        model = Person
        fields = ["name"]
        widgets = {
            "name": forms.TextInput(attrs={"class": "input", "placeholder": "Enter name"})
        }