# Bouldering Route App — ML core

Коллекция пройденных боулдеринговых трасс: пользователь загружает фото,
тапает зацепку, модель (fine-tuned YOLO11n-seg) находит все зацепки,
цветовой фильтр выделяет трассу, фон отрезается.

## Структура

```
core/       эталонный пайплайн: детекция + отбор трассы по цвету (LAB, ΔE)
training/   датасет ClimbInst → YOLO-формат, fine-tune YOLO11n-seg (Apple MPS)
demo/       временная веб-заглушка (FastAPI + canvas)
ios/        приложение BoulderBook (SwiftUI + SwiftData + CoreML)
data/       датасеты (не в git)
models/     веса обученных моделей (не в git)
```

## iOS-приложение

Сборка: `cd ios && xcodegen generate && xcodebuild ...` или открыть
`ios/BoulderBook.xcodeproj` в Xcode (для запуска на телефине выбрать свою
Team в Signing & Capabilities, Cmd+R).

- Инференс полностью на устройстве: CoreML 11 МБ, полный декод масок на Swift
- Цветовое ядро — порт `core/pipeline.py`, фикстуры общие (7/7 тестов)
- Демо-режим: запуск с аргументом `-demoSeed` наполняет коллекцию
  тестовыми фото из датасета


## Запуск

```bash
.venv/bin/python -m training.download_data      # ~1.5k фото с HuggingFace
.venv/bin/python -m training.convert_to_yolo    # Labelme → YOLO-seg
.venv/bin/python -m training.train              # fine-tune, ~1 час на M1 Pro
.venv/bin/python -m pytest core                 # фикстуры пайплайна
.venv/bin/python -m demo.server                 # http://127.0.0.1:8000
```

## Датасет и лицензия

[ClimbInst](https://huggingface.co/datasets/ClimbVision/ClimbInst):
1509 фото, 89k инстансов, единый класс «hold», сплиты 1169/290/50.
Разметка: SAM3 + ручная коррекция (Labelme).

**Лицензия CC BY-NC-SA 4.0 — только некоммерческое использование.**
Для коммерческого релиза датасет придётся заменить/дополнить своими данными.

## Ядро (эталон для Swift-порта)

`core/pipeline.py`:

- `hold_from_polygon` — маска зацепки → средний цвет в LAB
- `RouteSession.pick_reference(x, y)` — эталон под тапом (меньшая площадь при перекрытии)
- `RouteSession.auto_select(max_de)` — отбор зацепок в радиусе ΔE от эталона
- `RouteSession.toggle(id)` — ручная коррекция
- `RouteSession.export_cutout()` — RGBA с прозрачным фоном

Тесты `core/test_pipeline.py` на синтетической стене — те же фикстуры
используются при сверке Swift-порта (этап 5 плана).
