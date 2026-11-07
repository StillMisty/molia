#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// 与 Dart 侧 `lib/services/window/window_chrome_io.dart` 的通道名成对。
constexpr char kWindowChannelName[] = "top.stillmisty.molia/window";

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;

  // 主窗口归 GTK 所有；这里只借指针判断「已经建过窗」。
  GtkWindow* main_window;

  // 原生 -> Dart 的窗口通道：GApplication 重复 activate 时发 `reopen`。
  FlMethodChannel* window_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void main_window_destroyed(GtkWidget* widget, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->main_window = nullptr;
  g_clear_object(&self->window_channel);
}

// Dart 返回成功时由 WindowChrome.show() 负责恢复（含托盘休眠树重建）；
// 通道还没接上 / 返回错误时才在原生侧兜底 present，避免用户点了没反应。
static void reopen_response_cb(GObject* source,
                               GAsyncResult* result,
                               gpointer user_data) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      fl_method_channel_invoke_method_finish(FL_METHOD_CHANNEL(source), result,
                                             &error);
  if (response != nullptr && FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
    return;
  }

  MyApplication* self = MY_APPLICATION(user_data);
  if (self->main_window != nullptr) {
    gtk_window_present(self->main_window);
  }
}

// 请 Dart 走统一的 WindowChrome.show()：托盘隐藏时界面是休眠占位树，
// 原生直接 gtk_window_present 会显示一扇空窗。
static void request_window_show(MyApplication* self) {
  if (self->main_window == nullptr) {
    return;
  }
  if (self->window_channel == nullptr) {
    gtk_window_present(self->main_window);
    return;
  }
  fl_method_channel_invoke_method(self->window_channel, "reopen", nullptr,
                                  nullptr, reopen_response_cb, self);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // GApplication 单实例：重复启动 / 桌面图标再次点击会再次发 activate。
  // 已有窗口时不再建第二扇窗，只请 Dart 恢复已有窗口。
  if (self->main_window != nullptr) {
    request_window_show(self);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Molia");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Molia");
  }

  gtk_window_set_default_size(window, 1280, 800);

  self->main_window = window;
  g_signal_connect(window, "destroy", G_CALLBACK(main_window_destroyed), self);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // 保存原生 -> Dart 通道：GApplication 的重复 activate 从这里回到
  // WindowChrome.show()。窗口 / 引擎销毁时一起释放。
  FlEngine* engine = fl_view_get_engine(view);
  if (engine != nullptr) {
    self->window_channel = fl_method_channel_new(
        fl_engine_get_binary_messenger(engine), kWindowChannelName,
        FL_METHOD_CODEC(fl_standard_method_codec_new()));
  }

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    // 没有 session bus（headless / 极简 WM）时退回非唯一模式：Dart 文件锁
    // 仍是跨会话的最终仲裁，应用不能因为拿不到 D-Bus 就起不来。
    g_warning("Failed to register GApplication: %s", error->message);
    g_clear_error(&error);
    g_application_set_flags(application, G_APPLICATION_NON_UNIQUE);
    if (!g_application_register(application, nullptr, &error)) {
      g_warning("Failed to register non-unique GApplication: %s",
                error->message);
      *exit_status = 1;
      return TRUE;
    }
  }

  // 主实例：创建窗口。远程实例：GApplication 把 Activate 转发给主实例后
  // 这里立即返回，进程退出。
  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_channel);
  self->main_window = nullptr;
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->dart_entrypoint_arguments = nullptr;
  self->main_window = nullptr;
  self->window_channel = nullptr;
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // 单实例默认交给 GApplication 的 D-Bus 激活：重复启动会转发激活并带上
  // startup notification token（Wayland 抢焦点必需）。测试 / 开发实例用
  // 环境变量退出唯一模式；tool/agent/*.sh 默认导出。
  GApplicationFlags flags = G_APPLICATION_DEFAULT_FLAGS;
  if (g_strcmp0(g_getenv("MOLIA_SINGLE_INSTANCE_DISABLED"), "1") == 0) {
    flags = G_APPLICATION_NON_UNIQUE;
  }

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
