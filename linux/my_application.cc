#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication
{
  GtkApplication parent_instance;
  char **dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Минимальный размер содержимого окна — minimumWindowSize в
// lib/features/window/notifier/window_notifier.dart. Задаётся здесь, а не только
// через window_manager: его setMinimumSize пишет подсказки в GdkWindow, и GTK
// затирает их своими при следующей раскладке — на Wayland окно сжималось как угодно.
#define MIN_CONTENT_WIDTH 390
#define MIN_CONTENT_HEIGHT 780

// Значок окна (для X11; на Wayland значок берётся из .desktop по app_id) —
// из ресурсов Flutter рядом с исполняемым файлом, а не из текущей папки.
static void set_window_icon(GtkWindow *window)
{
  g_autofree gchar *exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr)
    return;
  g_autofree gchar *dir = g_path_get_dirname(exe);
  g_autofree gchar *icon = g_build_filename(dir, "data", "flutter_assets", "assets", "images", "source",
                                            "ic_launcher_border.png", nullptr);
  gtk_window_set_icon_from_file(window, icon, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication *application)
{
  MyApplication *self = MY_APPLICATION(application);

  GList *windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows)
  {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow *window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  set_window_icon(window);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen *screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen))
  {
    const gchar *wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0)
    {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar)
  {
    GtkHeaderBar *header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "AxiOm");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  }
  else
  {
    gtk_window_set_title(window, "AxiOm");
  }

  gtk_window_set_default_size(window, 1280, 720);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView *view = fl_view_new(project);
  gtk_widget_set_size_request(GTK_WIDGET(view), MIN_CONTENT_WIDTH, MIN_CONTENT_HEIGHT);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  // Flutter 3.24 breaks the gtk_widget_realize solution: https://github.com/leanflutter/window_manager/issues/179#issuecomment-2299534856
  gtk_widget_hide(GTK_WIDGET(window));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication *application, gchar ***arguments, int *exit_status)
{
  MyApplication *self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error))
  {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return FALSE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication *application)
{
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication *application)
{
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject *object)
{
  MyApplication *self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass *klass)
{
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication *self) {}

MyApplication *my_application_new()
{
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_HANDLES_COMMAND_LINE | G_APPLICATION_HANDLES_OPEN,
                                     nullptr));
}
