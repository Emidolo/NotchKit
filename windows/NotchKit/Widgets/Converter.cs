using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace NotchKit;

sealed class ConvertItem(string path, Kind kind)
{
    public enum States { Waiting, Running, Done, Failed }
    public string Path => path;
    public Kind Kind => kind;
    public States State = States.Waiting;
    /// Fraction done while running, or null when it can't be measured.
    public double? Fraction;
    public List<string> Outputs = [];
    public string Error = "";
}

sealed class ConverterModel
{
    public static readonly ConverterModel Shared = new();
    record Options(string Format, double Quality, int? MaxPixel, double Dpi, string? Directory);

    public List<ConvertItem> Items { get; } = [];
    string format = "png";
    public string Format
    {
        get => format;
        set
        {
            if (value == format) return;
            format = value;
            // A new target format means finished files are worth converting again.
            if (!IsRunning) foreach (var item in Items) item.State = ConvertItem.States.Waiting;
            Ui.Changed();
        }
    }
    public double Quality = 0.85;
    /// Longest side in pixels for image output; empty keeps the original size.
    public string MaxPixel = "";
    public double Dpi = 150;
    /// null saves next to each original.
    public string? OutputDirectory
    {
        get => Prefs.Get<string?>("converterOutputDirectory", null);
        set => Prefs.Set("converterOutputDirectory", value);
    }
    public bool IsRunning { get; private set; }
    CancellationTokenSource? running;

    public List<string> Targets => Formats.Common(Items.Select(i => i.Kind));
    public bool HasPdf => Items.Any(i => i.Kind == Kind.Pdf);
    public bool CanConvert => Targets.Count > 0 && Items.Any(i => i.State != ConvertItem.States.Done);

    /// Fraction of the list converted so far; null when nothing is running.
    public double? Progress => !IsRunning || Items.Count == 0 ? null
        : Items.Sum(i => i.State switch { ConvertItem.States.Done => 1, ConvertItem.States.Running => i.Fraction ?? 0, _ => 0 }) / Items.Count;

    /// A tool this batch needs but that isn't installed.
    public string? MissingTool =>
        (Format == "webp" || Items.Any(i => i.Kind is Kind.Video or Kind.Audio)) && Tool.Find("ffmpeg") == null ? "ffmpeg" : null;

    /// Unsupported files and folders are skipped.
    public void Add(IEnumerable<string> paths)
    {
        foreach (var path in paths)
            if (File.Exists(path) && Formats.KindOf(path) is Kind kind && !Items.Any(i => i.Path == path)) Items.Add(new ConvertItem(path, kind));
        FixFormat();
    }

    public void Remove(ConvertItem item)
    {
        Items.Remove(item);
        FixFormat();
    }

    public void Clear()
    {
        Stop();
        Items.Clear();
        Ui.Changed();
    }

    void FixFormat()
    {
        if (Targets.Count > 0 && !Targets.Contains(Format)) Format = Targets[0];
        Ui.Changed();
    }

    public void PickFiles()
    {
        var dialog = new OpenFileDialog { Multiselect = true };
        if (dialog.ShowDialog() == true) Add(dialog.FileNames);
        // The notch closed when the cursor left for the dialog.
        NotchWindow.Shared.Expand();
    }

    public void PickOutputDirectory()
    {
        if (Startup.ChooseFolder(OutputDirectory) is string folder) OutputDirectory = folder;
        NotchWindow.Shared.Expand();
        Ui.Changed();
    }

    public void Stop() => running?.Cancel();

    public async void Convert()
    {
        if (IsRunning || !CanConvert) return;
        var options = new Options(Format, Quality, int.TryParse(MaxPixel, out var max) && max > 0 ? max : null, Dpi, OutputDirectory);
        // A merged PDF always contains the whole list, even files that were already converted.
        var batch = Format == "pdf" ? Items.ToList() : Items.Where(i => i.State != ConvertItem.States.Done).ToList();
        var cancel = (running = new CancellationTokenSource()).Token;
        IsRunning = true;
        KeepAwake.Shared.Evaluate();
        if (options.Format == "pdf") await Merge(batch, options);
        // One at a time: ffmpeg already uses every core.
        else foreach (var item in batch.TakeWhile(_ => !cancel.IsCancellationRequested)) await Convert(item, options, cancel);
        IsRunning = false;
        running = null;
        KeepAwake.Shared.Evaluate();
        Ui.Changed();
    }

    async Task Convert(ConvertItem item, Options options, CancellationToken cancel)
    {
        item.State = ConvertItem.States.Running;
        item.Fraction = null;
        Ui.Changed();
        var directory = options.Directory ?? Path.GetDirectoryName(item.Path)!;
        var name = Path.GetFileNameWithoutExtension(item.Path);
        try
        {
            item.Outputs = item.Kind switch
            {
                Kind.Image when options.Format == "webp" => [await WebP(item.Path, directory, name, options, cancel)],
                Kind.Image => [await Task.Run(() => Images.Convert(item.Path, Formats.FreePath(directory, name, options.Format), options.Format, options.Quality, options.MaxPixel))],
                Kind.Pdf => await Task.Run(() => Images.Rasterize(item.Path, directory, name, options.Format, options.Dpi, options.Quality,
                    fraction => Application.Current.Dispatcher.InvokeAsync(() => { item.Fraction = fraction; Ui.Changed(); }))),
                _ => [await Ffmpeg(item, directory, name, options.Format, cancel)],
            };
            item.State = ConvertItem.States.Done;
        }
        catch (Exception e)   // anything a decoder, encoder or tool throws is shown on the row
        {
            item.State = cancel.IsCancellationRequested ? ConvertItem.States.Waiting : ConvertItem.States.Failed;
            item.Error = e.Message;
        }
        Ui.Changed();
    }

    static async Task<string> WebP(string source, string directory, string name, Options options, CancellationToken cancel)
    {
        var ffmpeg = Tool.Find("ffmpeg") ?? throw new FileNotFoundException("ffmpeg is not installed");
        // Windows reads HEIC, JPEG and the rest but can't write WebP; ffmpeg can, from a PNG.
        var png = Path.Combine(Path.GetTempPath(), $"NotchKit-{Guid.NewGuid()}.png");
        try
        {
            await Task.Run(() => Images.Convert(source, png, "png", 1, options.MaxPixel));
            var destination = Formats.FreePath(directory, name, "webp");
            var quality = ((int)(options.Quality * 100)).ToString(CultureInfo.InvariantCulture);
            var result = await Tool.Run(ffmpeg, ["-nostdin", "-n", "-v", "error", "-i", png, "-c:v", "libwebp", "-quality", quality, destination], cancel: cancel);
            if (result.Status != 0) throw new IOException(Tool.LastError(result, "ffmpeg failed"));
            return destination;
        }
        finally { File.Delete(png); }
    }

    static async Task<string> Ffmpeg(ConvertItem item, string directory, string name, string format, CancellationToken cancel)
    {
        var ffmpeg = Tool.Find("ffmpeg") ?? throw new FileNotFoundException("ffmpeg is not installed");
        double duration = 0;
        if (Tool.Find("ffprobe") is string ffprobe)
        {
            var probe = await Tool.Run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", item.Path], cancel: cancel);
            double.TryParse(probe.Output.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out duration);
        }
        // Encode into a file of our own, so a failed or cancelled run never leaves a half-written
        // result behind and cleaning up can never delete somebody else's file.
        var partial = Path.Combine(directory, $".NotchKit-{Guid.NewGuid()}.{format}");
        var result = await Tool.Run(ffmpeg, Formats.FfmpegArguments(item.Path, partial, format), line =>
        {
            if (duration > 0 && Formats.ProgressSeconds(line) is double done)
            {
                item.Fraction = Math.Min(done / duration, 1);
                Ui.Changed();
            }
        }, cancel);
        if (result.Status != 0 || cancel.IsCancellationRequested)
        {
            File.Delete(partial);
            throw new IOException(Tool.LastError(result, "ffmpeg failed"));
        }
        var destination = Formats.FreePath(directory, name, format);
        File.Move(partial, destination);
        return destination;
    }

    async Task Merge(List<ConvertItem> batch, Options options)
    {
        var first = batch[0].Path;
        var name = Path.GetFileNameWithoutExtension(first) + (batch.Count > 1 ? " merged" : "");
        var destination = Formats.FreePath(options.Directory ?? Path.GetDirectoryName(first)!, name, "pdf");
        foreach (var item in batch) item.State = ConvertItem.States.Running;
        Ui.Changed();
        try
        {
            await Task.Run(() => Images.MakePdf(batch.Select(i => i.Path).ToList(), destination));
            foreach (var item in batch) { item.State = ConvertItem.States.Done; item.Outputs = [destination]; }
        }
        catch (Exception e)
        {
            foreach (var item in batch) { item.State = ConvertItem.States.Failed; item.Error = e.Message; }
        }
    }
}

/// The image engines, on Windows Imaging Component (through WPF) and Windows.Data.Pdf. Safe off the UI thread.
static class Images
{
    /// `maxPixel` caps the longest side; images are never scaled up.
    public static BitmapSource Load(string path, int? maxPixel)
    {
        var decoder = BitmapDecoder.Create(new Uri(path), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        BitmapSource image = decoder.Frames[0];
        var transforms = new TransformGroup();
        var longest = Math.Max(image.PixelWidth, image.PixelHeight);
        if (maxPixel is int max && max < longest) transforms.Children.Add(new ScaleTransform((double)max / longest, (double)max / longest));
        // ponytail: first frame only (animated GIFs come out still), and of the EXIF orientations only the rotations
        // (3, 6, 8) are applied; mirrored ones need a ScaleTransform(-1, 1) too.
        var rotation = Orientation(decoder.Frames[0]) switch { 3 => 180, 6 => 90, 8 => 270, _ => 0 };
        if (rotation != 0) transforms.Children.Add(new RotateTransform(rotation));
        if (transforms.Children.Count > 0) image = new TransformedBitmap(image, transforms);
        image.Freeze();
        return image;
    }

    static int Orientation(BitmapFrame frame)
    {
        try { return frame.Metadata is BitmapMetadata metadata && metadata.GetQuery("System.Photo.Orientation") is ushort o ? o : 1; }
        catch (Exception) { return 1; }   // formats without metadata throw instead of returning nothing
    }

    /// JPEG and BMP have no alpha: transparent pixels are laid on white rather than left to turn black.
    static BitmapSource Flatten(BitmapSource source)
    {
        var bgra = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        int width = bgra.PixelWidth, height = bgra.PixelHeight, stride = width * 4;
        var pixels = new byte[stride * height];
        bgra.CopyPixels(pixels, stride, 0);
        for (var i = 0; i < pixels.Length; i += 4)
        {
            int alpha = pixels[i + 3];
            for (var c = 0; c < 3; c++) pixels[i + c] = (byte)((pixels[i + c] * alpha + 255 * (255 - alpha)) / 255);
        }
        var flat = BitmapSource.Create(width, height, source.DpiX, source.DpiY, PixelFormats.Bgr32, null, pixels, stride);
        flat.Freeze();
        return flat;
    }

    static string Save(BitmapSource image, string destination, string format, double quality)
    {
        BitmapEncoder encoder = format switch
        {
            "jpg" => new JpegBitmapEncoder { QualityLevel = Math.Clamp((int)(quality * 100), 1, 100) },
            "tiff" => new TiffBitmapEncoder(),
            "gif" => new GifBitmapEncoder(),
            "bmp" => new BmpBitmapEncoder(),
            _ => new PngBitmapEncoder(),
        };
        encoder.Frames.Add(BitmapFrame.Create(format is "jpg" or "bmp" ? Flatten(image) : image));
        // CreateNew: never replaces a file, even one that appeared since the name was picked.
        using var file = new FileStream(destination, FileMode.CreateNew);
        try { encoder.Save(file); }
        catch
        {
            file.Dispose();
            File.Delete(destination);
            throw;
        }
        return destination;
    }

    public static string Convert(string source, string destination, string format, double quality, int? maxPixel) =>
        Save(Load(source, maxPixel), destination, format, quality);

    /// One image per page: "name-1.png", "name-2.png"… (just "name.png" for a single page).
    public static async Task<List<string>> Rasterize(string path, string directory, string name, string format, double dpi, double quality, Action<double> progress)
    {
        PdfDocument document;
        try { document = await PdfDocument.LoadFromFileAsync(await StorageFile.GetFileFromPathAsync(path)); }
        catch (Exception) { throw new InvalidDataException("Can't read this PDF. Is it password protected?"); }
        var outputs = new List<string>();
        for (uint index = 0; index < document.PageCount; index++)
        {
            using var page = document.GetPage(index);
            using var stream = new InMemoryRandomAccessStream();
            // Page sizes are in DIPs (1/96 inch); Windows applies the page's rotation.
            await page.RenderToStreamAsync(stream, new PdfPageRenderOptions
            {
                DestinationWidth = (uint)Math.Round(page.Size.Width * dpi / 96),
                DestinationHeight = (uint)Math.Round(page.Size.Height * dpi / 96),
                BackgroundColor = new Windows.UI.Color { A = 255, R = 255, G = 255, B = 255 },
            });
            stream.Seek(0);
            var decoder = BitmapDecoder.Create(stream.AsStreamForRead(), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            var destination = Formats.FreePath(directory, document.PageCount > 1 ? $"{name}-{index + 1}" : name, format);
            outputs.Add(Save(decoder.Frames[0], destination, format, quality));
            progress((double)(index + 1) / document.PageCount);
        }
        return outputs;
    }

    /// Images, in order, become one PDF with a page each.
    public static void MakePdf(IReadOnlyList<string> sources, string destination)
    {
        var pages = new List<Pdf.Page>();
        foreach (var source in sources)
        {
            var image = Flatten(Load(source, null));
            var encoder = new JpegBitmapEncoder { QualityLevel = 90 };
            encoder.Frames.Add(BitmapFrame.Create(image));
            using var jpeg = new MemoryStream();
            encoder.Save(jpeg);
            double dpiX = image.DpiX > 0 ? image.DpiX : 72, dpiY = image.DpiY > 0 ? image.DpiY : 72;
            pages.Add(new(jpeg.ToArray(), image.PixelWidth, image.PixelHeight, image.PixelWidth * 72 / dpiX, image.PixelHeight * 72 / dpiY));
        }
        using var file = new FileStream(destination, FileMode.CreateNew);
        file.Write(Pdf.FromJpegs(pages));
    }
}

sealed class ConverterView : Grid
{
    readonly FrameworkElement empty;
    readonly Grid content = new();
    readonly StackPanel rows = new();
    readonly ComboBox format, dpi;
    readonly TextBox maxPixel = new() { Width = 70, ToolTip = "Longest side in pixels. Leave empty to keep the original size." };
    readonly StackPanel quality;
    readonly TextBlock qualityValue = Ui.Label("", 12, Ui.Secondary);
    readonly ContentControl toolNote = new();
    readonly TextBlock noCommon = Ui.Label("These files have no output format in common.", 12, Ui.Secondary);
    readonly Button convert, stop;

    public ConverterView()
    {
        var model = ConverterModel.Shared;
        empty = Ui.Column(8, Ui.EmptyHint(G.Download, "Drop files on the notch", "Images, PDFs, video and audio"), Ui.TextButton("Choose Files…", model.PickFiles));
        ((FrameworkElement)((Panel)empty).Children[1]).HorizontalAlignment = HorizontalAlignment.Center;

        format = Ui.Picker("Output format", v => model.Format = v);
        dpi = Ui.Picker("Resolution", v => { model.Dpi = double.Parse(v, CultureInfo.InvariantCulture); });
        Ui.SetOptions(dpi, new[] { 72, 150, 300, 600 }.Select(d => ($"{d} DPI", d.ToString(CultureInfo.InvariantCulture))), "150");
        System.Windows.Automation.AutomationProperties.SetName(maxPixel, "Maximum size in pixels");
        maxPixel.TextChanged += (_, _) => model.MaxPixel = maxPixel.Text;
        var slider = Ui.Slider("Quality", 0.1, 1, model.Quality, v => { model.Quality = v; qualityValue.Text = $"{(int)(v * 100)}"; });
        slider.Width = 130;
        qualityValue.Text = $"{(int)(model.Quality * 100)}";
        quality = Ui.Row(6, Ui.Label("Quality", 12, Ui.Secondary), slider, qualityValue);

        var folder = Ui.IconButton(G.Folder, "Output folder", () => { });
        folder.ContextMenu = new ContextMenu();
        var same = new MenuItem { Header = "Same Folder as Original" };
        same.Click += (_, _) => { model.OutputDirectory = null; Ui.Changed(); };
        var choose = new MenuItem { Header = "Choose Folder…" };
        choose.Click += (_, _) => model.PickOutputDirectory();
        folder.ContextMenu.Items.Add(same);
        folder.ContextMenu.Items.Add(choose);
        folder.Click += (_, _) => { folder.ContextMenu.PlacementTarget = folder; folder.ContextMenu.IsOpen = true; };
        folder.ToolTipOpening += (_, _) => folder.ToolTip = $"Save to: {model.OutputDirectory ?? "same folder as the original"}";

        convert = Ui.TextButton("Convert", model.Convert, accent: true);
        stop = Ui.TextButton("Stop", model.Stop);
        var actions = new DockPanel();
        var go = Ui.Row(0, convert, stop);
        DockPanel.SetDock(go, Dock.Right);
        actions.Children.Add(go);
        actions.Children.Add(Ui.Row(4, Ui.IconButton(G.Add, "Add files", model.PickFiles), folder, Ui.IconButton(G.Delete, "Clear list", model.Clear)));

        var options = new DockPanel { Width = 240, Margin = new Thickness(14, 0, 0, 0) };
        DockPanel.SetDock(actions, Dock.Bottom);
        options.Children.Add(actions);
        options.Children.Add(Ui.Column(6, noCommon, Ui.Row(6, format, dpi, maxPixel), quality, toolNote));
        options.Children[^1].SetValue(VerticalAlignmentProperty, VerticalAlignment.Top);

        content.ColumnDefinitions.Add(new ColumnDefinition());
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.Children.Add(new ScrollViewer { Content = rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        SetColumn(options, 1);
        content.Children.Add(options);
        Children.Add(empty);
        Children.Add(content);
        Ui.Refresh += Update;
        Update();
    }

    void Update()
    {
        var model = ConverterModel.Shared;
        empty.Visibility = model.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        content.Visibility = model.Items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (model.Items.Count == 0) return;

        rows.Children.Clear();
        foreach (var item in model.Items) rows.Children.Add(Row(item, model));

        var targets = model.Targets;
        noCommon.Visibility = targets.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        format.Visibility = targets.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        Ui.SetOptions(format, targets.Select(f => (f == "pdf" && model.Items.Count > 1 ? "One PDF" : f.ToUpperInvariant(), f)), model.Format);
        var imageOutput = targets.Count > 0 && model.Format != "pdf" && model.Items.All(i => i.Kind is Kind.Image or Kind.Pdf);
        dpi.Visibility = imageOutput && model.HasPdf ? Visibility.Visible : Visibility.Collapsed;
        maxPixel.Visibility = imageOutput && !model.HasPdf ? Visibility.Visible : Visibility.Collapsed;
        var missing = model.MissingTool;
        toolNote.Content = missing == null ? null : Ui.Row(6, Ui.Label($"Needs {missing}", 12, Ui.Orange), ToolInstaller.Button(missing));
        quality.Visibility = missing == null && targets.Count > 0 && Formats.HasQuality(model.Format) ? Visibility.Visible : Visibility.Collapsed;
        convert.Visibility = model.IsRunning ? Visibility.Collapsed : Visibility.Visible;
        convert.IsEnabled = model.CanConvert && missing == null;
        stop.Visibility = model.IsRunning ? Visibility.Visible : Visibility.Collapsed;
    }

    static FrameworkElement Row(ConvertItem item, ConverterModel model)
    {
        var row = new DockPanel { Height = 26 };
        var glyph = item.Kind switch { Kind.Image => G.Photo, Kind.Pdf => G.Document, Kind.Video => G.Film, _ => G.Music };
        var icon = Ui.Icon(glyph, 13, Ui.Secondary);
        icon.Width = 20;
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        var remove = Ui.IconButton(G.Close, "Remove", () => model.Remove(item), 11);
        remove.IsEnabled = !model.IsRunning;
        UIElement status = item.State switch
        {
            ConvertItem.States.Waiting => remove,
            ConvertItem.States.Running => new ProgressBar
            {
                Width = 70, Height = 4, Minimum = 0, Maximum = 1, Value = item.Fraction ?? 0, IsIndeterminate = item.Fraction == null,
                VerticalAlignment = VerticalAlignment.Center,
            },
            ConvertItem.States.Done => Ui.IconButton(G.Reveal, "Show in Explorer", () => Ui.Reveal(item.Outputs[0]), 13),
            _ => Ui.Row(4, Ui.Icon(G.Warning, 12, Ui.Red), new TextBlock
            {
                Text = item.Error, Foreground = Ui.Red, FontSize = 12, MaxWidth = 170, ToolTip = item.Error,
                TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center,
            }, remove),
        };
        DockPanel.SetDock(status, Dock.Right);
        row.Children.Add(status);
        row.Children.Add(Ui.Label(System.IO.Path.GetFileName(item.Path)));
        return row;
    }
}
