/*
 * scan-eval.c — offline matcher evaluation on scans saved with
 * VALIDITY0088_DUMP_SCANS=<dir> (files <time>-<action>-f<finger>.pgm).
 *
 * Rebuilds one print per finger from its "enroll" scans (in time order),
 * then scores every probe ("verify" scans, and every enroll scan against
 * the prints of the other fingers) with the driver's SIFT matcher, exactly
 * like verify: best score over the print's templates.
 *
 * Build (from the repository root):
 *   cc -O2 -o scan-eval tools/scan-eval.c drivers/validity-0088/validity-sift.c \
 *      -Idrivers/validity-0088 $(pkg-config --cflags --libs glib-2.0) -lm
 * Run:
 *   ./scan-eval <dir> [threshold...]
 *
 * The scans are biometric data: keep them out of the repository.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "validity-sift.h"

#define W 56
#define H 144
#define MAX_FINGERS 11

typedef struct
{
  gchar                *name;
  gchar                *action;
  gint                  finger;
  ValiditySiftFeatures *feat;
} Scan;

static const gchar *finger_names[MAX_FINGERS] = {
  "?", "L-thumb", "L-index", "L-middle", "L-ring", "L-little",
  "R-thumb", "R-index", "R-middle", "R-ring", "R-little",
};

static gint
cmp_name (gconstpointer a, gconstpointer b)
{
  return g_strcmp0 (*(const gchar * const *) a, *(const gchar * const *) b);
}

static gboolean
load_pgm (const gchar *path, guint8 *px)
{
  g_autofree gchar *data = NULL;
  gsize len;
  gint w, h, max, off = 0;

  if (!g_file_get_contents (path, &data, &len, NULL) ||
      sscanf (data, "P5 %d %d %d%n", &w, &h, &max, &off) != 3 ||
      w != W || h != H || (gsize) off + 1 + W * H > len)
    return FALSE;
  memcpy (px, data + off + 1, W * H);
  return TRUE;
}

/* Best score of @probe over the templates of finger @f's print, skipping
 * template @skip (the probe itself) if it is part of that print. */
static gint
score_print (const Scan *probe, GPtrArray *print, const Scan *skip)
{
  gint best = 0;

  for (guint i = 0; i < print->len; i++)
    {
      const Scan *t = g_ptr_array_index (print, i);
      gint v;

      if (t == skip)
        continue;
      v = validity_sift_match (probe->feat, t->feat);
      best = MAX (best, v);
    }
  return best;
}

static gint
cmp_int (gconstpointer a, gconstpointer b)
{
  return *(const gint *) a - *(const gint *) b;
}

static void
summary (const gchar *what, GArray *v)
{
  gint n = v->len;

  if (n == 0)
    {
      printf ("%-34s none\n", what);
      return;
    }
  g_array_sort (v, cmp_int);
  printf ("%-34s n=%-5d min %3d  p5 %3d  median %3d  p95 %3d  max %3d\n", what, n,
          g_array_index (v, gint, 0), g_array_index (v, gint, n * 5 / 100),
          g_array_index (v, gint, n / 2), g_array_index (v, gint, n * 95 / 100),
          g_array_index (v, gint, n - 1));
}

static gint
count_ge (GArray *v, gint t)
{
  gint c = 0;

  for (guint i = 0; i < v->len; i++)
    c += g_array_index (v, gint, i) >= t;
  return c;
}

int
main (int argc, char **argv)
{
  g_autoptr(GDir) dir = NULL;
  g_autoptr(GPtrArray) names = g_ptr_array_new_with_free_func (g_free);
  g_autoptr(GPtrArray) scans = g_ptr_array_new ();
  GPtrArray *prints[MAX_FINGERS] = { NULL };
  g_autoptr(GArray) genuine = g_array_new (FALSE, FALSE, sizeof (gint));
  g_autoptr(GArray) genuine_loo = g_array_new (FALSE, FALSE, sizeof (gint));
  g_autoptr(GArray) impostor = g_array_new (FALSE, FALSE, sizeof (gint));
  g_autoptr(GArray) impostor_enroll = g_array_new (FALSE, FALSE, sizeof (gint));
  gint thresholds[16] = { 8, 10, 12, 15, 20 }, nthr = 5;
  const gchar *name;
  guint8 px[W * H];

  if (argc < 2)
    {
      fprintf (stderr, "usage: %s <scan dir> [threshold...]\n", argv[0]);
      return 2;
    }
  if (argc > 2)
    for (nthr = 0; nthr < 16 && nthr + 2 < argc; nthr++)
      thresholds[nthr] = atoi (argv[nthr + 2]);

  dir = g_dir_open (argv[1], 0, NULL);
  if (dir == NULL)
    {
      fprintf (stderr, "cannot open %s\n", argv[1]);
      return 1;
    }
  while ((name = g_dir_read_name (dir)) != NULL)
    if (g_str_has_suffix (name, ".pgm"))
      g_ptr_array_add (names, g_strdup (name));
  g_ptr_array_sort (names, cmp_name);

  for (guint i = 0; i < names->len; i++)
    {
      const gchar *n = g_ptr_array_index (names, i);
      g_autofree gchar *path = g_build_filename (argv[1], n, NULL);
      gchar **parts = g_strsplit (n, "-", -1);
      guint np = g_strv_length (parts);
      Scan *s;

      if (np < 4 || !load_pgm (path, px))
        {
          fprintf (stderr, "skipping %s\n", n);
          g_strfreev (parts);
          continue;
        }
      s = g_new0 (Scan, 1);
      s->name = g_strdup (n);
      s->action = g_strdup (parts[np - 2]);
      s->finger = atoi (parts[np - 1] + 1);
      s->feat = validity_sift_extract (px, W, H);
      g_strfreev (parts);
      if (s->finger < 0 || s->finger >= MAX_FINGERS)
        s->finger = 0;
      g_ptr_array_add (scans, s);
      if (g_str_equal (s->action, "enroll") && s->finger > 0)
        {
          if (prints[s->finger] == NULL)
            prints[s->finger] = g_ptr_array_new ();
          g_ptr_array_add (prints[s->finger], s);
        }
    }

  printf ("scans: %u\nprints:", scans->len);
  for (gint f = 1; f < MAX_FINGERS; f++)
    if (prints[f] != NULL)
      printf (" %s(%u)", finger_names[f], prints[f]->len);
  printf ("\n\n");

  for (guint i = 0; i < scans->len; i++)
    {
      const Scan *s = g_ptr_array_index (scans, i);
      gboolean is_enroll = g_str_equal (s->action, "enroll");
      gint own = -1, best_other = 0, best_other_f = 0;

      for (gint f = 1; f < MAX_FINGERS; f++)
        {
          gint v;

          if (prints[f] == NULL)
            continue;
          v = score_print (s, prints[f], s);
          if (f == s->finger)
            {
              own = v;
              g_array_append_val (is_enroll ? genuine_loo : genuine, v);
            }
          else
            {
              g_array_append_val (is_enroll ? impostor_enroll : impostor, v);
              if (v > best_other)
                {
                  best_other = v;
                  best_other_f = f;
                }
            }
        }
      if (own >= 0 && best_other > own)
        printf ("check: %s scores %d vs its own finger but %d vs %s "
                "(wrong finger tapped?)\n", s->name, own, best_other,
                finger_names[best_other_f]);
    }

  printf ("\nscore distributions (best over a print's templates)\n");
  summary ("genuine (verify probes)", genuine);
  summary ("genuine (enroll, leave-one-out)", genuine_loo);
  summary ("impostor (verify probes)", impostor);
  summary ("impostor (enroll scans)", impostor_enroll);

  printf ("\nthreshold   false rejects (verify)   false accepts (all impostor)\n");
  for (gint t = 0; t < nthr; t++)
    {
      gint fr = (gint) genuine->len - count_ge (genuine, thresholds[t]);
      gint fa = count_ge (impostor, thresholds[t]) +
                count_ge (impostor_enroll, thresholds[t]);
      gint ni = impostor->len + impostor_enroll->len;

      printf ("%9d   %5d / %-5u %6.2f%%   %5d / %-5d %6.3f%%\n", thresholds[t],
              fr, genuine->len, genuine->len ? 100.0 * fr / genuine->len : 0.0,
              fa, ni, ni ? 100.0 * fa / ni : 0.0);
    }
  if (impostor->len + impostor_enroll->len > 0)
    printf ("\nwith 0 false accepts in N impostor comparisons, the false-accept\n"
            "rate is below about 3/N (95%% confidence): here %.3f%%\n",
            300.0 / (impostor->len + impostor_enroll->len));
  return 0;
}
