import threading

RESOURCE_INTENSIVE_PARSER_SLOT = threading.BoundedSemaphore()
