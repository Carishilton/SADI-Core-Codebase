﻿using System;
using System.Collections.Generic;
using System.Text;
using System.Net;
using System.IO;
using LitJson;
using IOInformatics.KE.PluginAPI;
using System.Windows.Forms;
using System.Collections;
using System.Threading;
using SemWeb;
using System.Diagnostics;
using System.Collections.Specialized;

namespace SADI.KEPlugin
{
    class SADIHelper
    {
        const string ResolverURI = "http://sadiframework.org/RESOURCES/KE/resolver";

        internal static void debug(String prefix, String message, Object arg)
        {
            Debug.WriteLine(message, prefix);
            if (arg != null)
            {
                Debug.Indent();
                if (arg is string)
                {
                    Debug.WriteLine(arg);
                }
                else if (arg is Store)
                {
                    Debug.WriteLine(SemWebHelper.storeToString(arg as Store));
                }
                else if (arg is IEnumerable)
                {
                    foreach (Object o in arg as IEnumerable)
                    {
                        Debug.WriteLine(o.ToString());
                    }
                }
                else if (arg != null)
                {
                    Debug.WriteLine(arg.ToString());
                }
                Debug.Unindent();
            }
            Debug.Flush();
        }

        internal static void trace(String prefix, String message, Object arg)
        {
            Trace.WriteLine(message, prefix);
            if (arg != null)
            {
                Trace.Indent();
                if (arg is string)
                {
                    Trace.WriteLine(arg);
                }
                else if (arg is Store)
                {
                    Trace.WriteLine(SemWebHelper.storeToString(arg as Store));
                }
                else if (arg is IEnumerable)
                {
                    foreach (Object o in arg as IEnumerable)
                    {
                        Trace.WriteLine(o.ToString());
                    }
                }
                else if (arg != null)
                {
                    Trace.WriteLine(arg.ToString());
                }
                Trace.Unindent();
            }
            Trace.Flush();
        }

        internal static void error(String prefix, String message, Object arg, Exception e)
        {
            Debug.WriteLine(message, prefix);
            if (arg != null)
            {
                Debug.Indent();
                if (arg is string)
                {
                    Debug.WriteLine(arg);
                }
                else if (arg is IEnumerable)
                {
                    foreach (Object o in arg as IEnumerable)
                    {
                        Debug.WriteLine(o.ToString());
                    }
                }
                else
                {
                    Debug.WriteLine(arg.ToString());
                }
                Debug.Write("error: ");
                Debug.WriteLine(e.Message);
                Debug.Write("source: ");
                Debug.WriteLine(e.Source);
                Debug.WriteLine(e.StackTrace);
                Debug.Unindent();
            }
            Debug.Flush();
        }

        internal static Uri GetResolverURI(IEntity node)
        {
            NameValueCollection col = System.Web.HttpUtility.ParseQueryString(string.Empty);
            col.Add("uri", node.Uri.ToString());
            return new Uri(ResolverURI + "?" + col.ToString());
        }
    }
}
